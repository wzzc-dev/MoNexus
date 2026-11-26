///|
test "plan digest is deterministic and binds the environment id" {
  let home = "/home/dev"
  let workspace = "/home/dev/work"
  let first = test_plan(home, workspace, "env_01ARYZ6S41")
  let second = test_plan(home, workspace, "env_01ARYZ6S41")
  let other = test_plan(home, workspace, "env_01ARYZ6S42")
  assert_eq(first.plan_digest, second.plan_digest)
  assert_true(first.plan_digest != other.plan_digest)
  assert_eq(
    first.scratch_dir,
    workspace + DEFAULT_SCRATCH_SUFFIX + "env_01ARYZ6S41",
  )
  assert_true(first.env_file.is_some())
  assert_eq(first.env_names.length(), 2)
  assert_eq(first.network, "none")
  assert_eq(first.user, "1000:1000")
  assert_true(!first.requires_approval)
}

///|
test "plan rejects an untrusted hash and a missing workspace mount" {
  let inputs : PlanInputs = {
    environment_id: "env_01ARYZ6S41",
    workspace_id: "wsp_01ARYZ6S41",
    worktree_id: "",
    machine_id: "",
    primary_id: @contracts.ORG_LOCAL,
    workspace_root: "/home/dev/work",
    scratch_root: "/home/dev/work" + DEFAULT_SCRATCH_SUFFIX + "env_01ARYZ6S41",
    env_values: [],
    extra_mounts: [],
  }
  match compute_environment_plan(test_recipe(), "sha256:abc", inputs, "/home/dev") {
    Ok(_) => fail("a malformed recipe hash must be refused")
    Err(error) =>
      assert_eq(error.code, @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE)
  }
  let mut recipe = test_recipe()
  recipe = {
    ..recipe,
    mounts: [
      {
        source: @recipes.MountScratch,
        target: "/scratch",
        mode: @recipes.MountReadOnly,
      },
    ],
  }
  match
    compute_environment_plan(recipe, test_recipe_hash, inputs, "/home/dev") {
    Ok(_) => fail("a recipe without a workspace mount must be refused")
    Err(error) => assert_eq(error.code, @contracts.ENVIRONMENT_ERR_UNSUPPORTED)
  }
}

///|
test "plan matching requires labels, limits, network and exact mounts" {
  let plan = test_plan("/home/dev", "/home/dev/work", "env_01ARYZ6S41")
  // Build an inspect value that matches the plan exactly.
  let labels = @docker.managed_labels(plan.identity)
  let mut inspect : @docker.ContainerInspect = {
    name: @docker.container_name(plan.identity),
    image: test_image_digest,
    status: "running",
    running: true,
    env_names: ["HOME", "PATH"],
    labels,
    network_mode: "none",
    init: true,
    restart_policy: "no",
    user: "1000:1000",
    memory_bytes: Some(4_294_967_296L),
    nano_cpus: Some(2_000_000_000L),
    pids_limit: Some(1_024L),
    mounts: [],
  }
  let planned_mounts : Array[@docker.InspectMount] = []
  for mount in plan.mounts {
    planned_mounts.push({
      kind: "bind",
      source: mount.host_path,
      destination: mount.container_path,
      read_only: mount.mode == "ro",
    })
  }
  inspect = { ..inspect, mounts: planned_mounts }
  assert_true(plan_matches_inspect(plan, inspect))
  // Any label, limit, network or mount difference refuses adoption.
  let wrong_labels : Array[(String, String)] = []
  for label in labels {
    wrong_labels.push((label.0, if label.0 == @docker.LABEL_MANAGED {
      "false"
    } else {
      label.1
    }))
  }
  assert_true(!plan_matches_inspect(plan, { ..inspect, labels: wrong_labels }))
  assert_true(!plan_matches_inspect(plan, { ..inspect, network_mode: "bridge" }))
  assert_true(!plan_matches_inspect(plan, { ..inspect, user: "root" }))
  assert_true(!plan_matches_inspect(plan, { ..inspect, memory_bytes: Some(1L) }))
  assert_true(
    !plan_matches_inspect(plan, { ..inspect, mounts: [] }),
  )
  assert_true(!plan_matches_inspect(plan, { ..inspect, env_names: ["HOME"] }))
}
