///|
/// Deterministic fixtures for the environment lifecycle tests. No daemon is
/// required: `FakeDocker` records every argv and answers from refs so each
/// success, failure and cancellation path is exercised exactly once.

///|
let test_recipe_hash : String = "sha256:" +
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

///|
let test_image_digest : String =
  "sha256:1111111111111111111111111111111111111111111111111111111111111111"

///|
fn test_recipe() -> @recipes.Recipe {
  {
    schema_version: 1,
    name: "tiny",
    version: "0.1.0",
    image: {
      reference: "docker.io/library/alpine",
      digest: test_image_digest,
    },
    workdir: Some("/workspace/project"),
    user: Some("1000:1000"),
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
    env_allowlist: Some(["HOME", "PATH"]),
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
      path: "/srv/recipes/tiny.json",
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
fn test_plan(
  home : String,
  workspace_root : String,
  environment_id : String,
) -> EnvironmentPlan raise {
  let inputs : PlanInputs = {
    environment_id,
    workspace_id: "wsp_01ARYZ6S41",
    worktree_id: "",
    machine_id: "",
    primary_id: @contracts.ORG_LOCAL,
    workspace_root,
    scratch_root: workspace_root + DEFAULT_SCRATCH_SUFFIX + environment_id,
    env_values: [
      { name: "HOME", value: "/home/dev" },
      { name: "PATH", value: "/usr/bin:/bin" },
    ],
    extra_mounts: [],
  }
  match
    compute_environment_plan(
      test_recipe(),
      test_recipe_hash,
      inputs,
      home,
    ) {
    Ok(value) => value
    Err(error) => fail("plan failed: " + error.to_string())
  }
}

///|
struct FakeDocker {
  calls : Ref[Array[Array[String]]]
  ops : Ref[Array[String]]
  pull_ok : Ref[Bool]
  pull_timeout : Ref[Bool]
  create_ok : Ref[Bool]
  start_ok : Ref[Bool]
  stop_ok : Ref[Bool]
  rm_ok : Ref[Bool]
  labels_ok : Ref[Bool]
  created : Ref[Bool]
  running : Ref[Bool]
  daemon_down_after_create : Ref[Bool]
  daemon_down : Ref[Bool]
  exec_mode : Ref[String]
  terminate_ok : Ref[Bool]
  env_file_mode : Ref[String]
}

///|
fn fake_docker() -> FakeDocker {
  let calls : Ref[Array[Array[String]]] = Ref([])
  let ops : Ref[Array[String]] = Ref([])
  {
    calls,
    ops,
    pull_ok: Ref(true),
    pull_timeout: Ref(false),
    create_ok: Ref(true),
    start_ok: Ref(true),
    stop_ok: Ref(true),
    rm_ok: Ref(true),
    labels_ok: Ref(true),
    created: Ref(false),
    running: Ref(false),
    daemon_down_after_create: Ref(false),
    daemon_down: Ref(false),
    exec_mode: Ref("ok"),
    terminate_ok: Ref(true),
    env_file_mode: Ref(""),
  }
}

///|
fn fake_inspect_json(
  fake : FakeDocker,
  identity : @docker.EnvironmentIdentity,
) -> String {
  let name = @docker.container_name(identity)
  let running = if fake.running.val { "true" } else { "false" }
  let status = if fake.running.val { "running" } else { "exited" }
  let managed = if fake.labels_ok.val { "true" } else { "false" }
  let labels = "\"monexus.managed\":\"" + managed +
    "\",\"monexus.primary_id\":\"" + identity.primary_id +
    "\",\"monexus.environment_id\":\"" + identity.environment_id +
    "\",\"monexus.workspace_id\":\"" + identity.workspace_id +
    "\",\"monexus.recipe_hash\":\"" + identity.recipe_hash + "\""
  let mounts = "[{\"Type\":\"bind\",\"Source\":\"/tmp/fake-workspace\",\"Destination\":\"/workspace\",\"RW\":true},{\"Type\":\"bind\",\"Source\":\"/tmp/fake-scratch\",\"Destination\":\"/scratch\",\"RW\":false}]"
  "[{\"Name\":\"/" + name + "\",\"State\":{\"Status\":\"" + status +
  "\",\"Running\":" + running +
  "},\"Config\":{\"Image\":\"" + test_image_digest + "\",\"User\":\"1000:1000\"," +
  "\"Env\":[\"HOME=/home/dev\",\"PATH=/usr/bin:/bin\"],\"Labels\":{" + labels +
  "}},\"HostConfig\":{\"NetworkMode\":\"none\",\"Init\":true," +
  "\"RestartPolicy\":{\"Name\":\"no\"},\"Memory\":4294967296," +
  "\"NanoCpus\":2000000000,\"PidsLimit\":1024},\"Mounts\":" + mounts + "}]"
}

///|
fn fake_runner(
  fake : FakeDocker,
  home : String,
  identity : @docker.EnvironmentIdentity,
) -> DockerRunner {
  let name = @docker.container_name(identity)
  let invoke : DockerInvoke = async fn(argv, timeout_s) {
    ignore(timeout_s)
    fake.calls.val.push(argv)
    if fake.daemon_down.val {
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_DOCKER_UNAVAILABLE,
          "cannot connect to the Docker daemon",
        ),
      )
    }
    let head = if argv.is_empty() { "" } else { argv[0] }
    if head == "pull" {
      if fake.pull_timeout.val {
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_TIMEOUT,
            "docker command timed out",
          ),
        )
      }
      if fake.pull_ok.val {
        return Ok({
          exit_code: 0,
          stdout: "pulled " + test_image_digest,
          stderr: "",
        })
      }
      return Ok({
        exit_code: 1,
        stdout: "",
        stderr: "manifest for image not found",
      })
    }
    if head == "image" && argv.length() > 1 && argv[1] == "inspect" {
      if fake.pull_ok.val && !fake.pull_timeout.val {
        return Ok({
          exit_code: 0,
          stdout: "[\"docker.io/library/alpine@" + test_image_digest + "\"]",
          stderr: "",
        })
      }
      return Ok({ exit_code: 1, stdout: "", stderr: "no such image" })
    }
    if head == "create" {
      if fake.create_ok.val {
        fake.created.val = true
        if fake.daemon_down_after_create.val {
          fake.daemon_down.val = true
        }
        return Ok({ exit_code: 0, stdout: "container-id", stderr: "" })
      }
      return Ok({
        exit_code: 125,
        stdout: "",
        stderr: "name already in use",
      })
    }
    if head == "start" {
      if fake.start_ok.val {
        fake.running.val = true
        return Ok({ exit_code: 0, stdout: name, stderr: "" })
      }
      return Ok({ exit_code: 1, stdout: "", stderr: "cannot start" })
    }
    if head == "inspect" {
      if !fake.created.val {
        return Ok({
          exit_code: 1,
          stdout: "",
          stderr: "Error: No such container: " + name,
        })
      }
      return Ok({
        exit_code: 0,
        stdout: fake_inspect_json(fake, identity),
        stderr: "",
      })
    }
    if head == "stop" {
      if !fake.created.val {
        return Ok({
          exit_code: 1,
          stdout: "",
          stderr: "Error: No such container: " + name,
        })
      }
      if fake.stop_ok.val {
        fake.running.val = false
        return Ok({ exit_code: 0, stdout: name, stderr: "" })
      }
      return Ok({ exit_code: 1, stdout: "", stderr: "cannot stop" })
    }
    if head == "rm" {
      if !fake.created.val {
        return Ok({
          exit_code: 1,
          stdout: "",
          stderr: "Error: No such container: " + name,
        })
      }
      if fake.rm_ok.val {
        fake.created.val = false
        fake.running.val = false
        return Ok({ exit_code: 0, stdout: name, stderr: "" })
      }
      return Ok({ exit_code: 1, stdout: "", stderr: "device busy: API_KEY=supersecretvalue" })
    }
    if head == "exec" {
      // The bounded TERM→KILL helper is a second docker exec; it is not the
      // user command and must not inherit the fake exec mode.
      if call_has_element_containing(argv, "monexus-exec-terminate") {
        if fake.terminate_ok.val {
          return Ok({ exit_code: 0, stdout: "", stderr: "" })
        }
        return Ok({
          exit_code: 3,
          stdout: "",
          stderr: "exec process group survived KILL",
        })
      }
      let mode = fake.exec_mode.val
      if mode == "timeout" {
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_TIMEOUT,
            "docker exec timed out",
          ),
        )
      }
      if mode == "hang" {
        @async.sleep(60_000)
        return Ok({ exit_code: 0, stdout: "", stderr: "" })
      }
      if mode == "exit7" {
        return Ok({
          exit_code: 7,
          stdout: "partial",
          stderr: "boom",
        })
      }
      if mode == "secret" {
        return Ok({
          exit_code: 0,
          stdout: "API_KEY=sk-live-supersecretvalue",
          stderr: "",
        })
      }
      return Ok({ exit_code: 0, stdout: "hello", stderr: "" })
    }
    if head == "info" {
      return Ok({ exit_code: 0, stdout: "{}", stderr: "" })
    }
    Ok({ exit_code: 0, stdout: "", stderr: "" })
  }
  let make_dir : PathOp = async fn(path) {
    fake.ops.val.push("mkdir " + path)
    fixture_make_dir(path)
  }
  let write_secret : WriteSecretOp = async fn(dir, variables) {
    fake.ops.val.push("write_secret " + dir)
    match @docker.write_env_file(dir, variables) {
      Ok(_) => {
        fake.env_file_mode.val = test_file_mode(dir + "/env")
        Ok(())
      }
      Err(error) => Err(env_failure_from_docker(error))
    }
  }
  let remove_file : PathOp = async fn(path) {
    fake.ops.val.push("remove_file " + path)
    fixture_remove_file(path)
  }
  let remove_dir : PathOp = async fn(path) {
    fake.ops.val.push("remove_dir " + path)
    fixture_remove_dir(path)
  }
  {
    machine_id: "",
    remote: false,
    home,
    target: None,
    invoke,
    make_dir,
    write_secret,
    remove_file,
    remove_dir,
  }
}

///|
async fn test_file_mode(path : String) -> String {
  let has_usr_bin = @fs.exists("/usr/bin/stat") catch { _ => false }
  let stat = if has_usr_bin { "/usr/bin/stat" } else { "/bin/stat" }
  let result = @process.collect_output(stat, ["-c", "%a", path]) catch {
    _ => return "stat-failed"
  }
  let (code, output, _) = result
  if code != 0 {
    return "stat-failed"
  }
  let text = output.text() catch { _ => "" }
  text.trim().to_owned()
}

///|
fn argv_has(argv : Array[String], value : String) -> Bool {
  for item in argv {
    if item == value {
      return true
    }
  }
  false
}

///|
fn calls_with_head(
  fake : FakeDocker,
  head : String,
) -> Array[Array[String]] {
  let out : Array[Array[String]] = []
  for call in fake.calls.val {
    if call.length() > 0 && call[0] == head {
      out.push(call)
    }
  }
  out
}

///|
fn call_has_element_containing(
  call : Array[String],
  needle : String,
) -> Bool {
  for item in call {
    if item.contains(needle) {
      return true
    }
  }
  false
}

///|
fn count_calls_containing(fake : FakeDocker, needle : String) -> Int {
  let mut count = 0
  for call in fake.calls.val {
    if call_has_element_containing(call, needle) {
      count = count + 1
    }
  }
  count
}

///|
async fn cleanup_root(root : String) -> Unit {
  @fs.rmdir(root, recursive=true) catch { _ => () }
}

///|
fn test_record(state : String) -> @contracts.EnvironmentRecord {
  {
    id: "env_01ARYZ6S41",
    workspace_id: "wsp_01ARYZ6S41",
    worktree_id: "",
    machine_id: "",
    backend: @contracts.ENVIRONMENT_BACKEND_DOCKER,
    recipe: "tiny@0.1.0",
    recipe_hash: test_recipe_hash,
    container_name: "monexus-env-env_01ARYZ6S41",
    state,
    plan_digest: test_recipe_hash,
    workdir: "/workspace/project",
    user: "1000:1000",
    network: "none",
    mounts: [],
    env_names: [],
    risk: @contracts.RISK_MEDIUM,
    approval_id: "",
    ephemeral: false,
    ttl_s: 0,
    client_request_id: "",
    created_at: "2026-02-01T00:00:00Z",
    updated_at: "2026-02-01T00:00:00Z",
    started_at: "",
    stopped_at: "",
    last_error: "",
    cleanup_ok: true,
    cleanup_detail: "",
  }
}

///|
fn inspect_matching_plan(plan : EnvironmentPlan, running : Bool) -> @docker.ContainerInspect {
  let planned_mounts : Array[@docker.InspectMount] = []
  for mount in plan.mounts {
    planned_mounts.push({
      kind: "bind",
      source: mount.host_path,
      destination: mount.container_path,
      read_only: mount.mode == "ro",
    })
  }
  let limits = plan.recipe.effective_limits()
  {
    name: @docker.container_name(plan.identity),
    image: test_image_digest,
    status: if running { "running" } else { "exited" },
    running,
    env_names: plan.env_names,
    labels: @docker.managed_labels(plan.identity),
    network_mode: plan.network,
    init: true,
    restart_policy: "no",
    user: plan.user,
    memory_bytes: Some(limits.memory_mb.to_int64() * 1_048_576L),
    nano_cpus: Some(limits.cpu_millis.to_int64() * 1_000_000L),
    pids_limit: Some(limits.pids.to_int64()),
    mounts: planned_mounts,
  }
}

///|
fn test_inspect(running : Bool) -> @docker.ContainerInspect {
  {
    name: "monexus-env-env_01ARYZ6S41",
    image: test_image_digest,
    status: if running { "running" } else { "exited" },
    running,
    env_names: [],
    labels: [],
    network_mode: "none",
    init: true,
    restart_policy: "no",
    user: "",
    memory_bytes: None,
    nano_cpus: None,
    pids_limit: None,
    mounts: [],
  }
}

///|
async fn fixture_make_dir(path : String) -> Result[Unit, EnvFailure] {
  @fs.mkdir(path, permission=0o700, recursive=true, allow_exist=true) catch {
    error =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot create environment directory",
        ).with_detail(error.to_string()),
      )
  }
  @fs.chmod(path, 0o700) catch { _ => () }
  Ok(())
}

///|
async fn fixture_remove_file(path : String) -> Result[Unit, EnvFailure] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok(())
  }
  @fs.remove(path) catch {
    error =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
          "cannot remove env file",
        ).with_detail(error.to_string()),
      )
  }
  let remains = @fs.exists(path) catch { _ => true }
  if remains {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
        "env file still exists after removal",
      ).with_detail(path),
    )
  }
  Ok(())
}

///|
async fn fixture_remove_dir(path : String) -> Result[Unit, EnvFailure] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok(())
  }
  @fs.rmdir(path, recursive=true) catch {
    error =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
          "cannot remove environment directory",
        ).with_detail(error.to_string()),
      )
  }
  Ok(())
}
