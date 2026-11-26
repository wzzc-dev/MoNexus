///|
/// Deterministic environment plan (ADR-0013 §3.1, §4.1).
///
/// A plan is derived only from the verified recipe, the registered
/// workspace/worktree roots and the caller's allowlisted environment names.
/// Its digest is what an approval Decision binds to; environment values are
/// deliberately absent so a plan digest can be logged and compared without
/// leaking secrets.

///|
pub const ENVIRONMENT_POLICY_VERSION : String = "a2.1"

///|
pub const DEFAULT_SCRATCH_SUFFIX : String = "-monexus-scratch-"

///|
pub(all) struct PlanInputs {
  environment_id : String
  workspace_id : String
  worktree_id : String
  machine_id : String
  primary_id : String
  workspace_root : String
  scratch_root : String
  env_values : Array[@contracts.EnvironmentEnvValue]
  extra_mounts : Array[@contracts.EnvironmentMount]
}

///|
pub(all) struct EnvironmentPlan {
  environment_id : String
  recipe : @recipes.Recipe
  recipe_hash : String
  identity : @docker.EnvironmentIdentity
  roots : @docker.ResolvedRoots
  extra_mounts : Array[@docker.ExtraMount]
  mounts : Array[@contracts.EnvironmentMount]
  variables : Array[@docker.EnvironmentVariable]
  env_names : Array[String]
  workdir : String
  network : String
  user : String
  risk : String
  start_high : Bool
  requires_approval : Bool
  plan_digest : String
  env_dir : String
  env_file : String?
  scratch_dir : String
  image_reference : String
}

///|
fn plan_failure(code : String, message : String, detail : String) -> EnvFailure {
  EnvFailure::new(code, message).with_detail(detail)
}

///|
fn path_within(base : String, path : String) -> Bool {
  if path == base {
    return true
  }
  if base.length() >= path.length() {
    return false
  }
  path.has_prefix(base) && path.get_char(base.length()) == Some('/')
}

///|
fn risk_rank(risk : String) -> Int {
  match risk {
    @contracts.RISK_LOW => 0
    @contracts.RISK_MEDIUM => 1
    @contracts.RISK_HIGH => 2
    @contracts.RISK_CRITICAL => 3
    _ => -1
  }
}

///|
fn max_risk(left : String, right : String) -> String {
  if risk_rank(right) > risk_rank(left) {
    right
  } else {
    left
  }
}

///|
fn has_prepare_hook(recipe : @recipes.Recipe) -> Bool {
  let hook = recipe.lifecycle.prepare
  match hook.command {
    @recipes.HookArgv(argv) => !argv.is_empty()
    @recipes.HookScript(script) => script.trim() != ""
  }
}

///|
fn has_start_hook(recipe : @recipes.Recipe) -> Bool {
  let hook = recipe.lifecycle.start
  match hook.command {
    @recipes.HookArgv(argv) => !argv.is_empty()
    @recipes.HookScript(script) => script.trim() != ""
  }
}

///|
fn is_root_user(user : String) -> Bool {
  user == "root" || user == "0" || user == "0:0"
}

///|
fn resolve_extra_source(
  mount : @contracts.EnvironmentMount,
  workspace_root : String,
  scratch_dir : String,
) -> Result[String, EnvFailure] {
  let source = if mount.source == "workspace" {
    workspace_root
  } else if mount.source == "scratch" {
    scratch_dir
  } else {
    mount.source
  }
  if !@recipes.is_valid_host_path(source) {
    return Err(
      plan_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "extra mount source is not an absolute host path",
        mount.source,
      ),
    )
  }
  let registered = path_within(workspace_root, source) ||
    path_within(scratch_dir, source)
  if !registered {
    return Err(
      plan_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "extra mount source is not a registered workspace or scratch root",
        source,
      ),
    )
  }
  Ok(source)
}

///|
fn digest_text(
  inputs : PlanInputs,
  recipe_hash : String,
  workdir : String,
  network : String,
  user : String,
  limits : @recipes.EffectiveLimits,
  mount_lines : Array[String],
  env_names : Array[String],
) -> String {
  let out = StringBuilder()
  out.write_string("monexus-environment-plan-v1\n")
  out.write_string("policy=" + ENVIRONMENT_POLICY_VERSION + "\n")
  out.write_string("environment_id=" + inputs.environment_id + "\n")
  out.write_string("workspace_id=" + inputs.workspace_id + "\n")
  out.write_string("worktree_id=" + inputs.worktree_id + "\n")
  out.write_string("machine_id=" + inputs.machine_id + "\n")
  out.write_string("primary_id=" + inputs.primary_id + "\n")
  out.write_string("recipe_hash=" + recipe_hash + "\n")
  out.write_string("workspace_root=" + inputs.workspace_root + "\n")
  out.write_string("scratch_root=" + inputs.scratch_root + "\n")
  out.write_string("workdir=" + workdir + "\n")
  out.write_string("network=" + network + "\n")
  out.write_string("user=" + user + "\n")
  out.write_string("cpu_millis=" + limits.cpu_millis.to_string() + "\n")
  out.write_string("memory_mb=" + limits.memory_mb.to_string() + "\n")
  out.write_string("pids=" + limits.pids.to_string() + "\n")
  let mut index = 0
  while index < mount_lines.length() {
    out.write_string("mount=" + mount_lines[index] + "\n")
    index = index + 1
  }
  index = 0
  while index < env_names.length() {
    out.write_string("env=" + env_names[index] + "\n")
    index = index + 1
  }
  out.to_string()
}

///|
/// Build the plan or refuse it with a stable code. `home` is the executing
/// machine home used for `~/.monexus/environments/<environment_id>/`.
///|
/// Compare a plan with an observed container. Only a container whose managed
/// labels, network, user, environment names and bind mounts all match the plan
/// may be adopted; a same-named container with different labels is never
/// touched.
fn plan_fields_match_inspect(
  identity : @docker.EnvironmentIdentity,
  network : String,
  user : String,
  env_names : Array[String],
  mounts : Array[@contracts.EnvironmentMount],
  recipe : @recipes.Recipe,
  inspect : @docker.ContainerInspect,
) -> Bool {
  if !@docker.inspect_matches_identity(inspect, identity) {
    return false
  }
  if inspect.network_mode != network || inspect.user != user {
    return false
  }
  if inspect.env_names.length() != env_names.length() {
    return false
  }
  for name in env_names {
    let mut found = false
    for observed in inspect.env_names {
      if observed == name {
        found = true
      }
    }
    if !found {
      return false
    }
  }
  if inspect.mounts.length() != mounts.length() {
    return false
  }
  for expected in mounts {
    let mut found = false
    for observed in inspect.mounts {
      if observed.source == expected.host_path &&
        observed.destination == expected.container_path &&
        observed.read_only == (expected.mode == "ro") {
        found = true
      }
    }
    if !found {
      return false
    }
  }
  // Docker reports the configured limits on the created container. A value
  // that is present must match the plan; absent means the engine did not
  // report it and is not treated as a mismatch.
  let limits = recipe.effective_limits()
  match inspect.memory_bytes {
    Some(value) =>
      if value != limits.memory_mb.to_int64() * 1_048_576L {
        return false
      }
    None => ()
  }
  match inspect.nano_cpus {
    Some(value) =>
      if value != limits.cpu_millis.to_int64() * 1_000_000L {
        return false
      }
    None => ()
  }
  match inspect.pids_limit {
    Some(value) =>
      if value != limits.pids.to_int64() {
        return false
      }
    None => ()
  }
  true
}

///|
/// Strict plan comparison for adoption. Every plan-derived field must match:
/// identity labels, network, user, env names, mounts and limits.
pub fn plan_matches_inspect(
  plan : EnvironmentPlan,
  inspect : @docker.ContainerInspect,
) -> Bool {
  plan_fields_match_inspect(
    plan.identity,
    plan.network,
    plan.user,
    plan.env_names,
    plan.mounts,
    plan.recipe,
    inspect,
  )
}

///|
/// Strict comparison for crash reconciliation, where the original plan object
/// is gone but its fields were recorded on the intent. The recipe is still
/// required: without a verified recipe the limits cannot be checked, and an
/// unverifiable container is never adopted.
pub fn record_matches_inspect(
  record : @contracts.EnvironmentRecord,
  identity : @docker.EnvironmentIdentity,
  inspect : @docker.ContainerInspect,
  recipe : @recipes.Recipe?,
) -> Bool {
  match recipe {
    Some(value) =>
      plan_fields_match_inspect(
        identity,
        record.network,
        record.user,
        record.env_names,
        record.mounts,
        value,
        inspect,
      )
    None => false
  }
}

///|
pub fn compute_environment_plan(
  recipe : @recipes.Recipe,
  recipe_hash : String,
  inputs : PlanInputs,
  home : String,
) -> Result[EnvironmentPlan, EnvFailure] {
  if !@recipes.is_valid_image_digest(recipe_hash) {
    return Err(
      plan_failure(
        @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
        "recipe hash is not a verified sha256 digest",
        recipe_hash,
      ),
    )
  }
  if inputs.environment_id == "" || !@docker.is_valid_runtime_id(inputs.environment_id) {
    return Err(
      plan_failure(
        @contracts.ENVIRONMENT_ERR_INVALID,
        "environment id is not a bounded runtime id",
        inputs.environment_id,
      ),
    )
  }
  if !@recipes.is_valid_host_path(inputs.workspace_root) ||
    !@recipes.is_valid_host_path(home) {
    return Err(
      plan_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "workspace root or home is not an absolute normalised host path",
        "",
      ),
    )
  }
  let workspace_mount = match recipe.workspace_mount() {
    Some(value) => value
    None =>
      return Err(
        plan_failure(
          @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
          "recipe must declare exactly one workspace mount (A2.1)",
          "mounts",
        ),
      )
  }
  ignore(workspace_mount)
  let scratch_dir = inputs.workspace_root + DEFAULT_SCRATCH_SUFFIX +
    inputs.environment_id
  if !@recipes.is_valid_host_path(scratch_dir) {
    return Err(
      plan_failure(
        @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
        "derived scratch root is not a valid host path",
        scratch_dir,
      ),
    )
  }
  let scratch_root = if recipe.scratch_mount() is Some(_) {
    scratch_dir
  } else {
    scratch_dir
  }
  let roots = match
    @docker.ResolvedRoots::new(
      workspace_root=inputs.workspace_root,
      scratch_root=scratch_root,
    ) {
    Ok(value) => value
    Err(error) => return Err(env_failure_from_docker(error))
  }
  let identity = match
    @docker.EnvironmentIdentity::new(
      environment_id=inputs.environment_id,
      primary_id=if inputs.primary_id == "" {
        @contracts.ORG_LOCAL
      } else {
        inputs.primary_id
      },
      workspace_id=inputs.workspace_id,
      recipe_hash=recipe_hash,
    ) {
    Ok(value) => value
    Err(error) => return Err(env_failure_from_docker(error))
  }
  let variables = match
    @docker.ordered_environment(
      recipe,
      inputs.env_values.map(fn(value) {
        { name: value.name, value: value.value }
      }),
    ) {
    Ok(value) => value
    Err(error) => return Err(env_failure_from_docker(error))
  }
  let env_names : Array[String] = []
  for variable in variables {
    env_names.push(variable.name)
  }
  let mount_lines : Array[String] = []
  let mounts : Array[@contracts.EnvironmentMount] = []
  for mount in recipe.mounts {
    let source = match mount.source {
      @recipes.MountWorkspace => "workspace"
      @recipes.MountScratch => "scratch"
    }
    let host_path = match mount.source {
      @recipes.MountWorkspace => inputs.workspace_root
      @recipes.MountScratch => scratch_root
    }
    let mode = mount.mode.label()
    mounts.push({
      source,
      host_path,
      container_path: mount.target,
      mode,
    })
    mount_lines.push(
      source + "|" + host_path + "|" + mount.target + "|" + mode,
    )
  }
  let extra : Array[@docker.ExtraMount] = []
  for requested in inputs.extra_mounts {
    let source = match
      resolve_extra_source(requested, inputs.workspace_root, scratch_dir) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let read_only = requested.mode != "rw"
    let extra_mount = match
      @docker.ExtraMount::new(
        source=source,
        target=requested.container_path,
        read_only=read_only,
      ) {
      Ok(value) => value
      Err(error) => return Err(env_failure_from_docker(error))
    }
    extra.push(extra_mount)
    mounts.push({
      source: "registered",
      host_path: source,
      container_path: requested.container_path,
      mode: if read_only { "ro" } else { "rw" },
    })
    mount_lines.push(
      "registered|" + source + "|" + requested.container_path + "|" +
      (if read_only { "ro" } else { "rw" }),
    )
  }
  let workdir = recipe.effective_workdir()
  let network = recipe.effective_network().label()
  let user = match recipe.user {
    Some(value) => value
    None => ""
  }
  let limits = recipe.effective_limits()
  let mut risk = @contracts.RISK_MEDIUM
  if recipe.effective_network() is @recipes.NetworkBridge {
    risk = @contracts.RISK_HIGH
  }
  if has_prepare_hook(recipe) {
    risk = @contracts.RISK_HIGH
  }
  let mut has_writable_extra = false
  for mount in extra {
    if !mount.read_only {
      has_writable_extra = true
    }
  }
  if has_writable_extra {
    risk = @contracts.RISK_HIGH
  }
  if is_root_user(user) {
    risk = max_risk(risk, @contracts.RISK_MEDIUM)
  }
  let requires_approval = risk_rank(risk) >= risk_rank(@contracts.RISK_HIGH) ||
    !extra.is_empty() || has_prepare_hook(recipe)
  let start_high = has_start_hook(recipe) ||
    (recipe.effective_network() is @recipes.NetworkBridge)
  let plan_digest = "sha256:" +
    @recipes.sha256_hex(
      digest_text(
        inputs,
        recipe_hash,
        workdir,
        network,
        user,
        limits,
        mount_lines,
        env_names,
      ),
    )
  let env_dir = home + "/.monexus/environments/" + inputs.environment_id
  let env_file = if variables.is_empty() {
    None
  } else {
    Some(env_dir + "/env")
  }
  Ok({
    environment_id: inputs.environment_id,
    recipe,
    recipe_hash,
    identity,
    roots,
    extra_mounts: extra,
    mounts,
    variables,
    env_names,
    workdir,
    network,
    user,
    risk,
    start_high,
    requires_approval,
    plan_digest,
    env_dir,
    env_file,
    scratch_dir,
    image_reference: @docker.image_pull_reference(recipe.image),
  })
}
