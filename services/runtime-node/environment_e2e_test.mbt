///|
/// A2.2 end-to-end: the A2.1 environment lifecycle running on a paired
/// runtime node. The same `create_container`/`exec_in_container`/
/// `run_container_terminal`/`destroy_container` calls used for local and SSH
/// machines go through `runtime.exec.*`, `runtime.fs.*` and `runtime.pty.*`
/// over the pinned TLS session. The node keeps no environment record or
/// approval state; the primary mints one-time grants against the published
/// policy snapshot.
///
/// Skipped when a Docker daemon or a local `nginx:alpine` repo digest is not
/// available, like the local real-Docker test.

///|
async fn e2e_env_docker_text(argv : Array[String]) -> (Int, String) {
  let collected = @process.collect_output("docker", argv) catch {
    _ => return (-1, "")
  }
  let (code, stdout, _) = collected
  let text = stdout.text() catch { _ => "" }
  (code, text.trim().to_owned())
}

///|
async fn e2e_env_image() -> (String, String)? {
  let (daemon_code, _) = e2e_env_docker_text(
    ["info", "--format", "{{.ServerVersion}}"],
  )
  if daemon_code != 0 {
    println("runtime environment e2e skipped: no reachable Docker daemon")
    return None
  }
  let (image_code, repo_digests) = e2e_env_docker_text(
    [
      "image",
      "inspect",
      "--format",
      "{{range .RepoDigests}}{{println .}}{{end}}",
      "nginx:alpine",
    ],
  )
  if image_code != 0 || repo_digests == "" {
    println(
      "runtime environment e2e skipped: nginx:alpine with a repo digest is not available locally",
    )
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
    println("runtime environment e2e skipped: nginx:alpine has no usable digest")
    return None
  }
  Some((image_ref, image_digest))
}

///|
let e2e_env_recipe_hash : String = "sha256:" +
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

///|
fn e2e_env_recipe(image_ref : String, image_digest : String) -> @recipes.Recipe {
  {
    schema_version: 1,
    name: "runtime-e2e",
    version: "0.1.0",
    image: { reference: image_ref, digest: image_digest },
    workdir: Some("/workspace/project"),
    user: Some("0:0"),
    mounts: [
      {
        source: @recipes.MountWorkspace,
        target: "/workspace",
        mode: @recipes.MountReadWrite,
      },
      {
        source: @recipes.MountScratch,
        target: "/scratch",
        mode: @recipes.MountReadOnly,
      },
    ],
    env_allowlist: Some(["HOME", "LANG", "PATH"]),
    limits: {
      cpu_millis: Some(2000),
      memory_mb: Some(4096),
      pids: Some(1024),
    },
    network: Some(@recipes.NetworkNone),
    lifecycle: {
      prepare: { command: @recipes.HookArgv([]), timeout_s: 5 },
      start: { command: @recipes.HookArgv([]), timeout_s: 5 },
      stop: { command: @recipes.HookArgv([]), timeout_s: 5 },
    },
    doctor: None,
    source: {
      kind: "local_file",
      path: "/srv/recipes/runtime-e2e.json",
      author: "ops",
      created_at: "2026-02-01T00:00:00Z",
    },
    signature: {
      key_id: "ops-key",
      alg: "ed25519",
      sig: "U1NIU0lHAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    },
  }
}

///|
/// The environment lifecycle needs the node policy to allow the operations it
/// actually issues: exec/PTY for the container, fs.write to place the env file
/// and create directories, fs.delete for cleanup, and control for cancel.
fn e2e_env_policy(version : String) -> @policy.PolicySnapshot {
  let now = @async.now()
  let rules = @policy.PolicyRules::new(
    allow_read_only=true,
    allowed_operations=[
      "control", "exec", "fs.write", "fs.delete", "pty", "git.write",
    ],
    env_allowlist=["HOME", "LANG", "PATH"],
  )
  match
    @policy.PolicySnapshot::new(
      version~,
      issued_at_ms=now - 1_000L,
      expires_at_ms=now + 3_600_000L,
      rules~,
    ) {
    Ok(value) => value
    Err(message) => abort("cannot build the environment policy: " + message)
  }
}

///|
async fn e2e_env_drain_terminal(
  output : @aqueue.Queue[@workspace.TerminalEvent],
) -> String {
  let text = StringBuilder()
  for ;; {
    let event = output.get() catch { _ => break }
    match event {
      @workspace.TerminalEvent::Data(value) => text.write_string(value)
      @workspace.TerminalEvent::Eof => break
    }
  }
  text.to_string()
}

///|
async test "environment lifecycle runs through a paired runtime node" {
  let (image_ref, image_digest) = match e2e_env_image() {
    Some(value) => value
    None => return
  }
  host_run_scenario(
    "mn-env-runtime-e2e",
    "rt-env-e2e",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    None,
    sandbox_home=true,
    async fn(h) {
      // Publish the lifecycle policy and wait for the node's ack; every
      // mutating docker/fs/pty call is gated on it.
      match h.state.publish_policy(e2e_env_policy("pol-env-e2e")) {
        Ok(_) => ()
        Err(message) => fail("cannot publish the environment policy: " + message)
      }
      host_wait_policy_ack(h.state, h.runtime_id, 10_000L)
      let probe = match h.machine.probe() {
        Ok(value) => value
        Err(error) => fail("probe failed: " + error.message)
      }
      assert_true(probe.home != "")
      assert_true(probe.capabilities.contains("docker"))
      let node_home = h.host.home()
      assert_eq(node_home, probe.home)
      let ops = match
        @environment.runtime_ops_for_machine(
          machine=h.machine,
          home=node_home,
          workspace_root=h.workspace,
        ) {
        Ok(value) => value
        Err(error) => fail("cannot build runtime ops: " + error.to_string())
      }
      let runner = @environment.runtime_runner(
        machine_id="m-env-e2e",
        home=node_home,
        ops~,
      )
      assert_true(runner.is_runtime())
      assert_eq(runner.home, node_home)
      let environment_id = @contracts.new_id("env", @async.now())
      let recipe = e2e_env_recipe(image_ref, image_digest)
      let scratch_root = node_home + "/.monexus/environments/" +
        environment_id + "/scratch"
      let inputs : @environment.PlanInputs = {
        environment_id,
        workspace_id: "wsp_runtime_e2e",
        worktree_id: "",
        machine_id: "m-env-e2e",
        primary_id: @contracts.ORG_LOCAL,
        workspace_root: h.workspace,
        scratch_root,
        env_values: [
          { name: "HOME", value: "/root" },
          {
            name: "PATH",
            value: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          },
        ],
        extra_mounts: [],
      }
      let plan = match
        @environment.compute_environment_plan(
          recipe,
          e2e_env_recipe_hash,
          inputs,
          node_home,
        ) {
        Ok(value) => value
        Err(error) => fail("runtime plan failed: " + error.to_string())
      }
      // The secret hand-off goes through the node's rooted fs: 0700 dir and a
      // 0600 env file, then the file is removed. No env value crosses a log or
      // an event.
      match
        (runner.write_secret)(plan.env_dir, plan.variables) {
        Ok(_) => ()
        Err(error) => fail("runtime env hand-off failed: " + error.to_string())
      }
      assert_eq(host_mode(plan.env_dir), 0o700)
      assert_eq(host_mode(plan.env_dir + "/env"), 0o600)
      match (runner.remove_file)(plan.env_dir + "/env") {
        Ok(_) => ()
        Err(error) => fail("runtime env file removal failed: " + error.to_string())
      }
      assert_true(!(@fs.exists(plan.env_dir + "/env") catch { _ => true }))
      // The same lifecycle calls as local/SSH, now over the paired node.
      match @environment.create_container(runner, plan) {
        Ok(_) => ()
        Err(failure) =>
          fail(
            "runtime create failed: " + failure.failure.to_string() + " / " +
            failure.cleanup_log,
          )
      }
      assert_eq(host_mode(plan.env_dir), 0o700)
      assert_eq(host_mode(plan.scratch_dir), 0o700)
      let inspected = match @environment.inspect_container(runner, plan.identity) {
        Ok(Some(value)) => value
        Ok(None) => fail("runtime create left no container")
        Err(error) => fail("cannot inspect the runtime container: " + error.to_string())
      }
      assert_true(inspected.running)
      // Recovery keys are the managed labels; a same-named container with
      // different labels is never touched. Image-declared ENV entries are not
      // plan-controlled, so the plan's names are checked as a subset; mounts
      // are exact.
      assert_true(@docker.inspect_matches_identity(inspected, plan.identity))
      for name in plan.env_names {
        assert_true(inspected.env_names.contains(name))
      }
      assert_eq(inspected.mounts.length(), plan.mounts.length())
      for expected in plan.mounts {
        let mut found = false
        for observed in inspected.mounts {
          if observed.source == expected.host_path &&
            observed.destination == expected.container_path &&
            observed.read_only == (expected.mode == "ro") {
            found = true
          }
        }
        assert_true(found)
      }
      // Exec inside the container through runtime.exec.*.
      match
        @environment.exec_in_container(
          runner,
          plan.identity,
          ["sh", "-c", "printf runtime-ok"],
          plan.workdir,
          30,
        ) {
        Ok(output) => {
          assert_eq(output.exit_code, 0)
          assert_true(output.stdout.contains("runtime-ok"))
          assert_true(!output.timed_out)
        }
        Err(error) => fail("runtime exec failed: " + error.to_string())
      }
      // A timeout must terminate the container-side process group; it is
      // reported as timed_out data, never as a successful exit.
      match
        @environment.exec_in_container(
          runner,
          plan.identity,
          ["sh", "-c", "sleep 30"],
          plan.workdir,
          1,
        ) {
        Ok(output) => {
          assert_true(output.timed_out)
          assert_eq(output.exit_code, -1)
        }
        Err(error) =>
          fail(
            "an unconfirmed runtime timeout must not be reported as executed: " +
            error.to_string(),
          )
      }
      // Interactive terminal through runtime.pty.*: the node streams durable
      // pty.output events instead of a pty.read method.
      let input : @aqueue.Queue[@workspace.TerminalInput] = @aqueue.Queue(
        kind=Unbounded,
      )
      let output : @aqueue.Queue[@workspace.TerminalEvent] = @aqueue.Queue(
        kind=Unbounded,
      )
      @environment.run_container_terminal(
        runner,
        plan.identity,
        "printf terminal-ok",
        plan.workdir,
        "",
        24,
        80,
        input,
        output,
      )
      let terminal_text = e2e_env_drain_terminal(output)
      assert_true(terminal_text.contains("terminal-ok"))
      // Destroy removes only the label-matched container and the node-side
      // environment/scratch directories; nothing else is pruned.
      let destroyed = @environment.destroy_container(
        runner,
        plan.identity,
        plan.env_dir,
        plan.scratch_dir,
      )
      if !destroyed.ok {
        fail("runtime destroy was not clean: " + destroyed.log)
      }
      match @environment.inspect_container(runner, plan.identity) {
        Ok(None) => ()
        Ok(Some(_)) => fail("destroy left the runtime container behind")
        Err(error) => fail("cannot confirm runtime destroy: " + error.to_string())
      }
      assert_true(!(@fs.exists(plan.env_dir) catch { _ => true }))
      assert_true(!(@fs.exists(plan.scratch_dir) catch { _ => true }))
    },
  )
}
