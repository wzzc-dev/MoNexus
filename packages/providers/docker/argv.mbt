///|
/// Exact Docker argv builders (ADR-0013 §3.2).
///
/// Every builder returns an argv array **excluding** the Docker executable;
/// each element is a separate string and no element is ever built by a shell.
/// The pinned create shape is:
///
///   create --name <name> --label ... --init --restart=no
///          --network <none|bridge> --workdir <w> [--user <u>]
///          --cpus <n> --memory <mb>m --pids-limit <n>
///          [--env-file <path>] --mount type=bind,source=<root>,target=<t>[,readonly]...
///          <repo>@<digest>
///
/// There is deliberately no `--rm`, no privileged/capability flag, no host
/// network, no port publishing and no arbitrary host bind: mounts resolve only
/// through the two roots in `ResolvedRoots`, and those roots are validated
/// here so a caller cannot smuggle an arbitrary host path through A2.2.

///|
pub const MAX_STOP_TIMEOUT_S : Int = 300

///|
pub const LABEL_MANAGED : String = "monexus.managed"

///|
pub const LABEL_PRIMARY_ID : String = "monexus.primary_id"

///|
pub const LABEL_ENVIRONMENT_ID : String = "monexus.environment_id"

///|
pub const LABEL_WORKSPACE_ID : String = "monexus.workspace_id"

///|
pub const LABEL_RECIPE_HASH : String = "monexus.recipe_hash"

///|
/// Validated identity for one environment container. `primary_id` is the
/// owner's primary/account scope, `workspace_id` the bound workspace and
/// `recipe_hash` the verified `sha256:<hex>` of the recipe.
pub(all) struct EnvironmentIdentity {
  environment_id : String
  primary_id : String
  workspace_id : String
  recipe_hash : String
}

///|
pub fn EnvironmentIdentity::new(
  environment_id~ : String,
  primary_id~ : String,
  workspace_id~ : String,
  recipe_hash~ : String,
) -> Result[EnvironmentIdentity, DockerError] {
  if !@recipes.is_valid_recipe_name(environment_id) {
    return Err(
      DockerError::new(InvalidEnvironmentId).at("environment_id").with_detail(
        "expected [a-z0-9][a-z0-9-]{0,63}",
      ),
    )
  }
  if !@recipes.is_valid_recipe_name(primary_id) {
    return Err(
      DockerError::new(InvalidPrimaryId).at("primary_id").with_detail(
        "expected [a-z0-9][a-z0-9-]{0,63}",
      ),
    )
  }
  if !@recipes.is_valid_recipe_name(workspace_id) {
    return Err(
      DockerError::new(InvalidWorkspaceId).at("workspace_id").with_detail(
        "expected [a-z0-9][a-z0-9-]{0,63}",
      ),
    )
  }
  if !@recipes.is_valid_image_digest(recipe_hash) {
    return Err(
      DockerError::new(InvalidRecipeHash).at("recipe_hash").with_detail(
        "expected sha256:<64 lowercase hex>",
      ),
    )
  }
  Ok({ environment_id, primary_id, workspace_id, recipe_hash })
}

///|
pub fn container_name(identity : EnvironmentIdentity) -> String {
  "monexus-env-" + identity.environment_id
}

///|
/// Managed labels in a fixed order. `monexus.managed=true` is what A2.2 uses
/// to recognise its own containers; nothing else is ever adopted.
pub fn managed_labels(
  identity : EnvironmentIdentity,
) -> Array[(String, String)] {
  [
    (LABEL_MANAGED, "true"),
    (LABEL_PRIMARY_ID, identity.primary_id),
    (LABEL_ENVIRONMENT_ID, identity.environment_id),
    (LABEL_WORKSPACE_ID, identity.workspace_id),
    (LABEL_RECIPE_HASH, identity.recipe_hash),
  ]
}

///|
/// Validated host roots. The provider never accepts a mount source from the
/// recipe: `workspace` and `scratch` are the only two sources, and both are
/// resolved to these roots by the caller (A2.1).
pub(all) struct ResolvedRoots {
  workspace_root : String
  scratch_root : String
}

///|
pub fn ResolvedRoots::new(
  workspace_root~ : String,
  scratch_root~ : String,
) -> Result[ResolvedRoots, DockerError] {
  match validate_root(workspace_root, "workspace_root") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match validate_root(scratch_root, "scratch_root") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if path_within(workspace_root, scratch_root) ||
    path_within(scratch_root, workspace_root) {
    return Err(
      DockerError::new(RootsOverlap).with_detail(
        "workspace and scratch roots must not contain each other",
      ),
    )
  }
  Ok({ workspace_root, scratch_root })
}

///|
fn validate_root(path : String, field : String) -> Result[Unit, DockerError] {
  if !@recipes.is_valid_host_path(path) {
    return Err(
      DockerError::new(InvalidRoot).at(field).with_detail(
        "expected an absolute normalised host path",
      ),
    )
  }
  if is_forbidden_root(path) {
    return Err(
      DockerError::new(ForbiddenRoot).at(field).with_detail(
        "root points at system state or owner secrets",
      ),
    )
  }
  Ok(())
}

///|
fn is_forbidden_root(path : String) -> Bool {
  if path == "/" {
    return true
  }
  let denied_bases = [
    "/proc", "/sys", "/dev", "/boot", "/etc", "/run", "/var/run",
  ]
  for base in denied_bases {
    if path == base || path.has_prefix(base + "/") {
      return true
    }
  }
  for secret_segment in [".ssh", ".aws", ".gnupg", ".kube", ".monexus"] {
    if has_segment(path, secret_segment) {
      return true
    }
  }
  let last = match path.rev_find("/") {
    Some(index) => path[index + 1:].to_owned()
    None => path
  }
  last == "docker.sock"
}

///|
fn has_segment(path : String, name : String) -> Bool {
  for part in path.split("/") {
    if part.to_owned() == name {
      return true
    }
  }
  false
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
fn mount_root(mount : @recipes.RecipeMount, roots : ResolvedRoots) -> String {
  match mount.source {
    @recipes.MountWorkspace => roots.workspace_root
    @recipes.MountScratch => roots.scratch_root
  }
}

///|
/// `type=bind,source=<root>,target=<target>[,readonly]`. The root comes from
/// `ResolvedRoots`, never from the recipe or an environment value.
fn mount_spec(mount : @recipes.RecipeMount, roots : ResolvedRoots) -> String {
  let mut spec = "type=bind,source=" + mount_root(mount, roots) + ",target=" +
    mount.target
  match mount.mode {
    @recipes.MountReadOnly => spec = spec + ",readonly"
    @recipes.MountReadWrite => ()
  }
  spec
}

///|
fn cpu_decimal(millis : Int) -> String {
  let whole = millis / 1000
  let remainder = millis % 1000
  let hundreds = remainder / 100
  let tens = (remainder / 10) % 10
  let ones = remainder % 10
  whole.to_string() + "." + (48 + hundreds).unsafe_to_char().to_string() +
  (48 + tens).unsafe_to_char().to_string() +
  (48 + ones).unsafe_to_char().to_string()
}

///|
pub fn image_pull_reference(image : @recipes.RecipeImage) -> String {
  image.reference + "@" + image.digest
}

///|
pub fn pull_argv(image : @recipes.RecipeImage) -> Array[String] {
  ["pull", image_pull_reference(image)]
}

///|
pub fn create_argv(
  recipe : @recipes.Recipe,
  identity : EnvironmentIdentity,
  roots : ResolvedRoots,
  env_file_path~ : String? = None,
) -> Result[Array[String], DockerError] {
  let env_path = match env_file_path {
    Some(value) => {
      if !@recipes.is_valid_host_path(value) {
        return Err(
          DockerError::new(EnvFileInvalid).at("env_file_path").with_detail(
            "expected an absolute normalised host path",
          ),
        )
      }
      Some(value)
    }
    None => None
  }
  let limits = recipe.effective_limits()
  let argv : Array[String] = ["create", "--name", container_name(identity)]
  for label in managed_labels(identity) {
    argv.push("--label")
    argv.push(label.0 + "=" + label.1)
  }
  argv.push("--init")
  argv.push("--restart=no")
  argv.push("--network")
  argv.push(recipe.effective_network().label())
  argv.push("--workdir")
  argv.push(recipe.effective_workdir())
  match recipe.user {
    Some(user) => {
      argv.push("--user")
      argv.push(user)
    }
    None => ()
  }
  argv.push("--cpus")
  argv.push(cpu_decimal(limits.cpu_millis))
  argv.push("--memory")
  argv.push(limits.memory_mb.to_string() + "m")
  argv.push("--pids-limit")
  argv.push(limits.pids.to_string())
  match env_path {
    Some(path) => {
      argv.push("--env-file")
      argv.push(path)
    }
    None => ()
  }
  for mount in recipe.mounts {
    argv.push("--mount")
    argv.push(mount_spec(mount, roots))
  }
  argv.push(image_pull_reference(recipe.image))
  Ok(argv)
}

///|
pub fn start_argv(identity : EnvironmentIdentity) -> Array[String] {
  ["start", container_name(identity)]
}

///|
pub fn stop_argv(
  identity : EnvironmentIdentity,
  timeout_s : Int,
) -> Result[Array[String], DockerError] {
  if timeout_s < 1 || timeout_s > MAX_STOP_TIMEOUT_S {
    return Err(
      DockerError::new(InvalidStopTimeout).at("timeout_s").with_detail(
        "expected 1..=300 seconds",
      ),
    )
  }
  Ok(["stop", "--time", timeout_s.to_string(), container_name(identity)])
}

///|
pub fn rm_argv(identity : EnvironmentIdentity) -> Array[String] {
  ["rm", "-f", container_name(identity)]
}

///|
pub fn inspect_argv(identity : EnvironmentIdentity) -> Array[String] {
  ["inspect", "--type", "container", container_name(identity)]
}
