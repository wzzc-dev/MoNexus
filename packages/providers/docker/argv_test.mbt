///|
/// Exact-argv tests (ADR-0013 §3.2). Every element is compared literally; the
/// builders must never re-join, quote or interpolate anything through a shell.

///|
fn expect_argv(actual : Array[String], expected : Array[String]) -> Unit raise {
  if actual.length() != expected.length() {
    fail(
      "argv length: expected " + expected.length().to_string() + ", got " +
      actual.length().to_string(),
    )
  }
  for index in 0..<expected.length() {
    if actual[index] != expected[index] {
      fail(
        "argv[" + index.to_string() + "]: expected " + expected[index] +
        ", got " + actual[index],
      )
    }
  }
}

///|
fn expect_docker_reject(result : Result[Array[String], @docker.DockerError], reason : String) -> Unit raise {
  match result {
    Ok(_) => fail("expected " + reason + " but argv was built")
    Err(error) =>
      if error.reason() != reason {
        fail("expected " + reason + " but got " + error.to_string())
      }
  }
}

///|
test "identity and container names are validated" {
  let identity = docker_identity()
  inspect(@docker.container_name(identity), content="monexus-env-env01")
  // A2.1 runtime ids include the upper-case ULID alphabet and `_`, unlike
  // recipe names.
  match @docker.EnvironmentIdentity::new(
    environment_id="env_01ARYZ6S41",
    primary_id="owner_01",
    workspace_id="ws_01",
    recipe_hash=FULL_RECIPE_HASH,
  ) {
    Ok(value) =>
      inspect(@docker.container_name(value), content="monexus-env-env_01ARYZ6S41")
    Err(error) => fail("a runtime id must be accepted: " + error.to_string())
  }
  let cases : Array[(String, String, String, String, String)] = [
    ("env 01", "owner01", "ws01", FULL_RECIPE_HASH, "invalid_environment_id"),
    ("env01", "Owner!", "ws01", FULL_RECIPE_HASH, "invalid_primary_id"),
    ("env01", "owner01", "ws/01", FULL_RECIPE_HASH, "invalid_workspace_id"),
    ("env01", "owner01", "ws01", "sha256:abc", "invalid_recipe_hash"),
  ]
  for entry in cases {
    match @docker.EnvironmentIdentity::new(
      environment_id=entry.0,
      primary_id=entry.1,
      workspace_id=entry.2,
      recipe_hash=entry.3,
    ) {
      Ok(_) => fail("identity should be rejected: " + entry.0)
      Err(error) =>
        if error.reason() != entry.4 {
          fail("expected " + entry.4 + " but got " + error.to_string())
        }
    }
  }
}

///|
test "roots reject system state, secrets, overlap and malformed paths" {
  let cases : Array[(String, String, String)] = [
    ("work", "/home/dev/scratch", "invalid_root"),
    ("/etc", "/home/dev/scratch", "forbidden_root"),
    ("/proc/self", "/home/dev/scratch", "forbidden_root"),
    ("/home/dev/.ssh/keys", "/home/dev/scratch", "forbidden_root"),
    ("/home/dev/work/", "/home/dev/scratch", "invalid_root"),
    ("/home/dev/../etc", "/home/dev/scratch", "invalid_root"),
    ("/home/dev/work", "/home/dev/work", "roots_overlap"),
    ("/home/dev/work", "/home/dev/work/scratch", "roots_overlap"),
    ("/home/dev/a,b", "/home/dev/scratch", "invalid_root"),
    ("/home/dev/$HOME", "/home/dev/scratch", "invalid_root"),
  ]
  for entry in cases {
    match @docker.ResolvedRoots::new(
      workspace_root=entry.0,
      scratch_root=entry.1,
    ) {
      Ok(_) => fail("roots should be rejected: " + entry.0)
      Err(error) =>
        if error.reason() != entry.2 {
          fail("expected " + entry.2 + " but got " + error.to_string())
        }
    }
  }
  // A root ending in the Docker socket is never a workspace.
  match @docker.ResolvedRoots::new(
    workspace_root="/run/docker.sock",
    scratch_root="/home/dev/scratch",
  ) {
    Ok(_) => fail("docker.sock must not be a root")
    Err(error) =>
      if error.reason() != "forbidden_root" {
        fail("expected forbidden_root but got " + error.to_string())
      }
  }
}

///|
test "create argv is exact for a fully declared recipe" {
  let recipe = docker_full_recipe()
  let identity = docker_identity()
  let roots = docker_roots()
  let argv = match @docker.create_argv(
    recipe,
    identity,
    roots,
    env_file_path=Some("/home/dev/.monexus/env/env"),
  ) {
    Ok(value) => value
    Err(error) => fail("create argv failed: " + error.to_string())
  }
  let expected : Array[String] = [
    "create", "--name", "monexus-env-env01", "--label", "monexus.managed=true",
    "--label", "monexus.primary_id=owner01", "--label",
    "monexus.environment_id=env01", "--label",
    "monexus.workspace_id=ws01", "--label",
    "monexus.recipe_hash=" + FULL_RECIPE_HASH, "--init", "--restart=no",
    "--network", "bridge", "--workdir", "/workspace/app", "--user", "1000:1000",
    "--cpus", "1.500", "--memory", "3072m", "--pids-limit", "256", "--env-file",
    "/home/dev/.monexus/env/env", "--mount",
    "type=bind,source=/home/dev/work,target=/workspace", "--mount",
    "type=bind,source=/home/dev/scratch,target=/scratch,readonly",
    "ghcr.io/acme/node-dev:1.0.0@sha256:3333333333333333333333333333333333333333333333333333333333333333",
  ]
  expect_argv(argv, expected)
  for element in argv {
    if element == "--rm" || element == "--privileged" {
      fail("forbidden docker flag present: " + element)
    }
  }
}

///|
test "create argv applies defaults and omits optional pieces" {
  let recipe = docker_minimal_recipe()
  let identity = docker_identity()
  let roots = docker_roots()
  let argv = match @docker.create_argv(recipe, identity, roots) {
    Ok(value) => value
    Err(error) => fail("create argv failed: " + error.to_string())
  }
  let expected : Array[String] = [
    "create", "--name", "monexus-env-env01", "--label", "monexus.managed=true",
    "--label", "monexus.primary_id=owner01", "--label",
    "monexus.environment_id=env01", "--label",
    "monexus.workspace_id=ws01", "--label",
    "monexus.recipe_hash=" + FULL_RECIPE_HASH, "--init", "--restart=no",
    "--network", "none", "--workdir", "/workspace", "--cpus", "1.000",
    "--memory", "2048m", "--pids-limit", "512", "--mount",
    "type=bind,source=/home/dev/work,target=/workspace",
    "docker.io/library/alpine@sha256:1111111111111111111111111111111111111111111111111111111111111111",
  ]
  expect_argv(argv, expected)
}

///|
test "paths stay literal argv elements even with spaces" {
  let recipe = docker_minimal_recipe()
  let identity = docker_identity()
  let roots = match @docker.ResolvedRoots::new(
    workspace_root="/home/dev/my work",
    scratch_root="/home/dev/scratch",
  ) {
    Ok(value) => value
    Err(error) => fail("space-containing root rejected: " + error.to_string())
  }
  let argv = match @docker.create_argv(recipe, identity, roots) {
    Ok(value) => value
    Err(error) => fail("create argv failed: " + error.to_string())
  }
  let mut found = false
  for element in argv {
    if element == "type=bind,source=/home/dev/my work,target=/workspace" {
      found = true
    }
  }
  if !found {
    fail("space-containing bind source was not kept in one argv element")
  }
}

///|
test "cpu limits render as fixed three-decimal values" {
  let recipe = docker_full_recipe()
  let identity = docker_identity()
  let roots = docker_roots()
  // The fixture declares 1500 millis; 1.500 is the exact Docker spelling.
  let argv = match @docker.create_argv(recipe, identity, roots) {
    Ok(value) => value
    Err(error) => fail("create argv failed: " + error.to_string())
  }
  let mut cpu = ""
  for index in 0..<(argv.length() - 1) {
    if argv[index] == "--cpus" {
      cpu = argv[index + 1]
    }
  }
  inspect(cpu, content="1.500")
}

///|
test "env-file paths are validated before entering argv" {
  let recipe = docker_minimal_recipe()
  let identity = docker_identity()
  let roots = docker_roots()
  expect_docker_reject(
    @docker.create_argv(
      recipe,
      identity,
      roots,
      env_file_path=Some("relative/env"),
    ),
    "env_file_invalid",
  )
  expect_docker_reject(
    @docker.create_argv(
      recipe,
      identity,
      roots,
      env_file_path=Some("/home/dev/a,b"),
    ),
    "env_file_invalid",
  )
}

///|
test "lifecycle argv builders are exact and bounded" {
  let identity = docker_identity()
  expect_argv(
    @docker.pull_argv(docker_full_recipe().image),
    [
      "pull",
      "ghcr.io/acme/node-dev:1.0.0@sha256:3333333333333333333333333333333333333333333333333333333333333333",
    ],
  )
  expect_argv(
    @docker.start_argv(identity),
    ["start", "monexus-env-env01"],
  )
  expect_argv(@docker.rm_argv(identity), ["rm", "-f", "monexus-env-env01"])
  expect_argv(
    @docker.inspect_argv(identity),
    ["inspect", "--type", "container", "monexus-env-env01"],
  )
  match @docker.stop_argv(identity, 10) {
    Ok(value) =>
      expect_argv(value, ["stop", "--time", "10", "monexus-env-env01"])
    Err(error) => fail("valid stop timeout rejected: " + error.to_string())
  }
  for bad in [0, 301, -1] {
    match @docker.stop_argv(identity, bad) {
      Ok(_) => fail("stop timeout should be rejected: " + bad.to_string())
      Err(error) =>
        if error.reason() != "invalid_stop_timeout" {
          fail("expected invalid_stop_timeout, got " + error.to_string())
        }
    }
  }
}
