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
/// A2.1 runtime ids (`env_<ULID>`, `wsp_<ULID>`, `org_local`) are *not* recipe
/// names: they contain `_` and uppercase ULID characters. This validator keeps
/// the label alphabet narrow (ASCII alphanumerics, `_`, `-`, bounded length)
/// without importing the recipe-name grammar that A2.0 deliberately narrowed
/// for recipe identity.
pub fn is_valid_runtime_id(text : String) -> Bool {
  if text.length() == 0 || text.length() > 64 {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let code = ch.to_int()
    let ok = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      code == 95 ||
      code == 45
    if !ok {
      return false
    }
  }
  true
}

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
  if !is_valid_runtime_id(environment_id) {
    return Err(
      DockerError::new(InvalidEnvironmentId).at("environment_id").with_detail(
        "expected a bounded [A-Za-z0-9_-] runtime id",
      ),
    )
  }
  if !is_valid_runtime_id(primary_id) {
    return Err(
      DockerError::new(InvalidPrimaryId).at("primary_id").with_detail(
        "expected a bounded [A-Za-z0-9_-] runtime id",
      ),
    )
  }
  if !is_valid_runtime_id(workspace_id) {
    return Err(
      DockerError::new(InvalidWorkspaceId).at("workspace_id").with_detail(
        "expected a bounded [A-Za-z0-9_-] runtime id",
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
/// An additional bind mount requested at create time (ADR-0013 §3.1
/// "extra registered mounts"). The source must already be a registered host
/// root: A2.1 resolves registration before reaching this builder, and the
/// same forbidden-root rules apply so an arbitrary host path cannot be
/// smuggled in. Extra mounts always force an environment approval.
pub(all) struct ExtraMount {
  source : String
  target : String
  read_only : Bool
}

///|
pub fn ExtraMount::new(
  source~ : String,
  target~ : String,
  read_only~ : Bool,
) -> Result[ExtraMount, DockerError] {
  match validate_root(source, "extra_mount.source") {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  if !@recipes.is_valid_container_path(target) {
    return Err(
      DockerError::new(InvalidContainerPath).at("extra_mount.target").with_detail(
        "expected an absolute normalised container path",
      ),
    )
  }
  Ok({ source, target, read_only })
}

///|
fn extra_mount_spec(mount : ExtraMount) -> String {
  let spec = "type=bind,source=" + mount.source + ",target=" + mount.target
  if mount.read_only {
    spec + ",readonly"
  } else {
    spec
  }
}

///|
pub fn create_argv(
  recipe : @recipes.Recipe,
  identity : EnvironmentIdentity,
  roots : ResolvedRoots,
  env_file_path~ : String? = None,
  extra_mounts~ : Array[ExtraMount] = [],
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
  for mount in extra_mounts {
    argv.push("--mount")
    argv.push(extra_mount_spec(mount))
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

///|
/// `exec [--workdir <cwd>] <container> <argv...>`. The command is an argv
/// array; there is no shell string field. Environment values are never passed
/// here (they would land in the host process argv), so callers rely on the
/// container's env-file-provided environment.
pub fn exec_argv(
  identity : EnvironmentIdentity,
  argv : Array[String],
  workdir~ : String = "",
) -> Result[Array[String], DockerError] {
  if argv.is_empty() {
    return Err(
      DockerError::new(Internal).at("argv").with_detail("exec argv is empty"),
    )
  }
  let out : Array[String] = ["exec"]
  if workdir != "" {
    if !@recipes.is_valid_container_path(workdir) {
      return Err(
        DockerError::new(InvalidContainerPath).at("workdir").with_detail(
          "expected an absolute normalised container path",
        ),
      )
    }
    out.push("--workdir")
    out.push(workdir)
  }
  out.push(container_name(identity))
  for arg in argv {
    out.push(arg)
  }
  Ok(out)
}

///|
/// Interactive exec argv for the terminal transport. `-i` keeps stdin open
/// and `-t` allocates a container TTY; the host allocates its own PTY or SSH
/// TTY in front of it.
pub fn exec_tty_argv(
  identity : EnvironmentIdentity,
  argv : Array[String],
  workdir~ : String = "",
) -> Result[Array[String], DockerError] {
  let base = match exec_argv(identity, argv, workdir~) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let out : Array[String] = ["exec", "-i", "-t"]
  for index in 1..<base.length() {
    out.push(base[index])
  }
  Ok(out)
}

///|
/// `docker version --format {{.Server.Version}}`, used by the doctor to
/// report the daemon version without changing state.
pub fn version_argv() -> Array[String] {
  ["version", "--format", "{{.Server.Version}}"]
}

///|
/// List only containers carrying the managed label. Reconcile never scans
/// unlabelled containers and never removes anything outside this set.
pub fn list_managed_argv() -> Array[String] {
  [
    "ps", "-a", "--filter", "label=" + LABEL_MANAGED + "=true", "--format",
    "{{.Names}}",
  ]
}

///|
/// Inspect one container by its exact name. Used by reconcile after a
/// labelled scan; the name still has to satisfy the managed-name shape before
/// it can be adopted.
pub fn inspect_named_argv(name : String) -> Result[Array[String], DockerError] {
  if !is_valid_runtime_id(name) {
    return Err(
      DockerError::new(InvalidEnvironmentId).at("name").with_detail(
        "container name is not a bounded runtime id",
      ),
    )
  }
  Ok(["inspect", "--type", "container", name])
}
