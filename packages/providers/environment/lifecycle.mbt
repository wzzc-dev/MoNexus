///|
/// Container lifecycle sequence (ADR-0013 §3.3–§3.5).
///
/// Every docker argv is built by `@docker`, every element stays a separate
/// argv entry, and only the deterministic, label-owned container name is
/// ever stopped or removed. `docker system prune` does not exist here.

///|
pub const PULL_TIMEOUT_S : Int = 900

///|
pub const CREATE_TIMEOUT_S : Int = 120

///|
pub const START_TIMEOUT_S : Int = 60

///|
pub const STOP_TIMEOUT_S : Int = 30

///|
pub const HOOK_TIMEOUT_MAX_S : Int = 3_600

///|
pub const RUNNING_WAIT_BUDGET_MS : Int = 20_000

///|
pub const REMOVE_TIMEOUT_S : Int = 60

///|
pub(all) struct CleanupOutcome {
  ok : Bool
  log : String
}

///|
fn cleanup_line(log : StringBuilder, text : String) -> Unit {
  log.write_string(@contracts.redact_secrets(text))
  log.write_char('\n')
}

///|
fn missing_container(result : DockerOutput) -> Bool {
  let text = (result.stdout + "\n" + result.stderr).to_lower()
  text.contains("no such container") || text.contains("no such object")
}

///|
pub fn docker_failure(
  code : String,
  message : String,
  result : DockerOutput,
) -> EnvFailure {
  let detail = if result.stderr.trim() != "" {
    result.stderr
  } else {
    result.stdout
  }
  EnvFailure::new(code, message).with_detail(detail)
}

///|
async fn inspect_raw(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
) -> Result[DockerOutput, EnvFailure] {
  (runner.invoke)(@docker.inspect_argv(identity), 30)
}

///|
/// Inspect one environment container. `Ok(None)` means the daemon answered
/// and the container does not exist; any other failure is an error.
pub async fn inspect_container(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
) -> Result[@docker.ContainerInspect?, EnvFailure] {
  let result = match inspect_raw(runner, identity) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    if missing_container(result) {
      return Ok(None)
    }
    return Err(
      docker_failure(
        @contracts.ENVIRONMENT_ERR_DOCKER_UNAVAILABLE,
        "docker inspect failed",
        result,
      ),
    )
  }
  let expected = @docker.container_name(identity)
  match @docker.parse_inspect(result.stdout, expected) {
    Ok(value) => Ok(Some(value))
    Err(error) => {
      let failure = env_failure_from_docker(error)
      Err(failure)
    }
  }
}

///|
/// Ownership classes for the deterministic container name. Only an `Owned`
/// container may be stopped, removed, exec'd or attached to; a container with
/// the same name but different managed labels is never touched.
enum ContainerOwnership {
  Owned(@docker.ContainerInspect)
  Absent
  Foreign(@docker.ContainerInspect)
}

///|
async fn container_ownership(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
) -> Result[ContainerOwnership, EnvFailure] {
  match inspect_container(runner, identity) {
    Ok(Some(value)) =>
      if @docker.inspect_matches_identity(value, identity) {
        Ok(Owned(value))
      } else {
        Ok(Foreign(value))
      }
    Ok(None) => Ok(Absent)
    Err(error) => Err(error)
  }
}

///|
async fn wait_until_running(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  budget_ms : Int,
) -> Result[@docker.ContainerInspect, EnvFailure] {
  let deadline = @async.now() + budget_ms.to_int64()
  for ;; {
    let inspect = match inspect_container(runner, identity) {
      Ok(Some(value)) => value
      Ok(None) =>
        return Err(
          EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_ORPHAN_SUSPECTED,
            "container is missing after start; run environment.doctor",
          ),
        )
      Err(error) => return Err(error)
    }
    if inspect.running {
      return Ok(inspect)
    }
    if @async.now() >= deadline {
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_TIMEOUT,
          "container did not reach running state within " +
          budget_ms.to_string() + "ms",
        ).with_detail(inspect.status),
      )
    }
    @async.sleep(250)
  }
}

///|
fn hook_argv(
  identity : @docker.EnvironmentIdentity,
  hook : @recipes.LifecycleHook,
  workdir : String,
) -> Result[Array[String], EnvFailure] {
  let command : Array[String] = match hook.command {
    @recipes.HookArgv(argv) => argv
    @recipes.HookScript(script) => ["sh", "-c", script]
  }
  if command.is_empty() {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_INVALID,
        "lifecycle hook command is empty",
      ),
    )
  }
  match @docker.exec_argv(identity, command, workdir=workdir) {
    Ok(value) => Ok(value)
    Err(error) => Err(env_failure_from_docker(error))
  }
}

///|
fn hook_timeout(hook : @recipes.LifecycleHook) -> Int {
  if hook.timeout_s < 1 {
    1
  } else if hook.timeout_s > HOOK_TIMEOUT_MAX_S {
    HOOK_TIMEOUT_MAX_S
  } else {
    hook.timeout_s
  }
}

///|
async fn run_hook(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  hook : @recipes.LifecycleHook,
  workdir : String,
) -> Result[Unit, EnvFailure] {
  let argv = match hook_argv(identity, hook, workdir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result = match (runner.invoke)(argv, hook_timeout(hook)) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code != 0 {
    return Err(
      docker_failure(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "lifecycle hook failed",
        result,
      ),
    )
  }
  Ok(())
}

///|
/// Remove the env file, the id-derived environment directory and (when the
/// recipe mounted scratch) its derived scratch directory. Never touches a
/// path that is not derived from the environment id.
pub async fn cleanup_environment(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  env_dir : String,
  scratch_dir : String,
) -> CleanupOutcome {
  let log = StringBuilder()
  let mut ok = true
  let mut remove_scratch = false
  match container_ownership(runner, identity) {
    Ok(Owned(_)) => {
      let stop = match @docker.stop_argv(identity, STOP_TIMEOUT_S) {
        Ok(argv) => { (runner.invoke)(argv, STOP_TIMEOUT_S + 10) }
        Err(error) => Err(env_failure_from_docker(error))
      }
      match stop {
        Ok(result) =>
          if result.exit_code == 0 || missing_container(result) {
            cleanup_line(log, "stop: ok")
          } else {
            ok = false
            cleanup_line(
              log,
              "stop: failed exit " + result.exit_code.to_string() + ": " +
              result.stderr,
            )
          }
        Err(error) => {
          ok = false
          cleanup_line(log, "stop: " + error.to_string())
        }
      }
      let rm = (runner.invoke)(@docker.rm_argv(identity), REMOVE_TIMEOUT_S)
      match rm {
        Ok(result) =>
          if result.exit_code == 0 || missing_container(result) {
            cleanup_line(log, "rm -f: ok")
            remove_scratch = true
          } else {
            ok = false
            cleanup_line(
              log,
              "rm -f: failed exit " + result.exit_code.to_string() + ": " +
              result.stderr,
            )
          }
        Err(error) => {
          ok = false
          cleanup_line(log, "rm -f: " + error.to_string())
        }
      }
    }
    Ok(Absent) => {
      cleanup_line(log, "container: absent")
      remove_scratch = true
    }
    Ok(Foreign(_)) => {
      // The deterministic name is held by a container with different managed
      // labels. It is not ours; leave it untouched.
      cleanup_line(log, "container labels do not match; left untouched")
    }
    Err(error) => {
      ok = false
      cleanup_line(log, "container ownership: " + error.to_string())
    }
  }
  match (runner.remove_file)(env_dir + "/env") {
    Ok(_) => cleanup_line(log, "env file: removed")
    Err(error) => {
      ok = false
      cleanup_line(log, "env file: " + error.to_string())
    }
  }
  match (runner.remove_dir)(env_dir) {
    Ok(_) => cleanup_line(log, "env dir: removed")
    Err(error) => {
      ok = false
      cleanup_line(log, "env dir: " + error.to_string())
    }
  }
  if remove_scratch {
    match (runner.remove_dir)(scratch_dir) {
      Ok(_) => cleanup_line(log, "scratch dir: removed")
      Err(error) => {
        ok = false
        cleanup_line(log, "scratch dir: " + error.to_string())
      }
    }
  } else {
    cleanup_line(log, "scratch dir: kept (ownership not confirmed)")
  }
  { ok, log: log.to_string(), }
}

///|
pub(all) struct CreateFailure {
  failure : EnvFailure
  cleanup_ok : Bool
  cleanup_log : String
}

///|
async fn create_failed(
  runner : DockerRunner,
  plan : EnvironmentPlan,
  failure : EnvFailure,
) -> Result[Unit, CreateFailure] {
  let cleanup = cleanup_environment(
    runner,
    plan.identity,
    plan.env_dir,
    plan.scratch_dir,
  )
  Err({
    failure,
    cleanup_ok: cleanup.ok,
    cleanup_log: cleanup.log,
  })
}

///|
/// Full create sequence. Storage must already hold the `creating` intent;
/// this function performs the docker changes and, on any failure, the reverse
/// cleanup matrix. The env file is deleted as soon as the container starts.
pub async fn create_container(
  runner : DockerRunner,
  plan : EnvironmentPlan,
) -> Result[Unit, CreateFailure] {
  match (runner.make_dir)(plan.env_dir) {
    Ok(_) => ()
    Err(error) => {
      return create_failed(runner, plan, error)
    }
  }
  match (runner.make_dir)(plan.scratch_dir) {
    Ok(_) => ()
    Err(error) => {
      return create_failed(runner, plan, error)
    }
  }
  match plan.env_file {
    Some(path) => {
      match (runner.write_secret)(plan.env_dir, plan.variables) {
        Ok(_) => ()
        Err(error) => {
          return create_failed(
            runner,
            plan,
            EnvFailure::new(
              @contracts.ENVIRONMENT_ERR_INVALID,
              "cannot write the environment env-file",
            ).with_detail(error.to_string()),
          )
        }
      }
      ignore(path)
    }
    None => ()
  }
  let pull = match
    (runner.invoke)(@docker.pull_argv(plan.recipe.image), PULL_TIMEOUT_S) {
    Ok(value) => value
    Err(error) => {
      return create_failed(runner, plan, error)
    }
  }
  if pull.exit_code != 0 {
    return create_failed(
      runner,
      plan,
      docker_failure(
        @contracts.ENVIRONMENT_ERR_DOCKER_UNAVAILABLE,
        "docker pull by digest failed",
        pull,
      ),
    )
  }
  // Pull-by-digest is rechecked before create: the local image must now be
  // addressable by the exact digest from the recipe.
  let inspected = match
    (runner.invoke)(
      [
        "image", "inspect", "--format", "{{json .RepoDigests}}",
        plan.image_reference,
      ],
      30,
    ) {
    Ok(value) => value
    Err(error) => {
      return create_failed(runner, plan, error)
    }
  }
  if inspected.exit_code != 0 ||
    !inspected.stdout.contains(plan.recipe.image.digest) {
    return create_failed(
      runner,
      plan,
      docker_failure(
        @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
        "pulled image digest does not match the recipe digest",
        inspected,
      ),
    )
  }
  let create = match
    @docker.create_argv(
      plan.recipe,
      plan.identity,
      plan.roots,
      env_file_path=plan.env_file,
      extra_mounts=plan.extra_mounts,
    ) {
    Ok(argv) => argv
    Err(error) => {
      return create_failed(runner, plan, env_failure_from_docker(error))
    }
  }
  let created = match (runner.invoke)(create, CREATE_TIMEOUT_S) {
    Ok(value) => value
    Err(error) => {
      return create_failed(runner, plan, error)
    }
  }
  if created.exit_code != 0 {
    return create_failed(
      runner,
      plan,
      docker_failure(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "docker create failed",
        created,
      ),
    )
  }
  let started = match
    (runner.invoke)(@docker.start_argv(plan.identity), START_TIMEOUT_S) {
    Ok(value) => value
    Err(error) => {
      return create_failed(runner, plan, error)
    }
  }
  if started.exit_code != 0 {
    return create_failed(
      runner,
      plan,
      docker_failure(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "docker start failed",
        started,
      ),
    )
  }
  match wait_until_running(runner, plan.identity, RUNNING_WAIT_BUDGET_MS) {
    Ok(_) => ()
    Err(error) => {
      return create_failed(runner, plan, error)
    }
  }
  // The env file has served its purpose; remove it before any lifecycle
  // hook so no on-disk copy of the values outlives startup.
  match (runner.remove_file)(plan.env_dir + "/env") {
    Ok(_) => ()
    Err(error) => {
      return create_failed(
        runner,
        plan,
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
          "cannot remove the env file after start",
        ).with_detail(error.to_string()),
      )
    }
  }
  let has_prepare = match plan.recipe.lifecycle.prepare.command {
    @recipes.HookArgv(argv) => !argv.is_empty()
    @recipes.HookScript(script) => script.trim() != ""
  }
  if has_prepare {
    match
      run_hook(
        runner,
        plan.identity,
        plan.recipe.lifecycle.prepare,
        plan.workdir,
      ) {
      Ok(_) => ()
      Err(error) => {
        return create_failed(runner, plan, error)
      }
    }
  }
  Ok(())
}

///|
/// Start an existing container and run the start hook when declared. A failed
/// start hook leaves the container stopped; it is never removed here.
pub async fn start_container(
  runner : DockerRunner,
  record : @contracts.EnvironmentRecord,
  recipe : @recipes.Recipe,
  identity : @docker.EnvironmentIdentity,
) -> Result[Unit, EnvFailure] {
  let existing = match inspect_container(runner, identity) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_ORPHAN_SUSPECTED,
          "container is missing; run environment.doctor",
        ),
      )
    Err(error) => return Err(error)
  }
  if !@docker.inspect_matches_identity(existing, identity) {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_CONFLICT,
        "container labels do not match the environment record",
      ),
    )
  }
  if !existing.running {
    let started = match
      (runner.invoke)(@docker.start_argv(identity), START_TIMEOUT_S) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if started.exit_code != 0 {
      return Err(
        docker_failure(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "docker start failed",
          started,
        ),
      )
    }
  }
  match wait_until_running(runner, identity, RUNNING_WAIT_BUDGET_MS) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let hook = recipe.lifecycle.start
  let has_hook = match hook.command {
    @recipes.HookArgv(argv) => !argv.is_empty()
    @recipes.HookScript(script) => script.trim() != ""
  }
  if has_hook {
    match run_hook(runner, identity, hook, record.workdir) {
      Ok(_) => ()
      Err(error) => {
        let stop = @docker.stop_argv(identity, STOP_TIMEOUT_S)
        match stop {
          Ok(argv) => {
            let _ = (runner.invoke)(argv, STOP_TIMEOUT_S + 10)
          }
          Err(_) => ()
        }
        return Err(error)
      }
    }
  }
  Ok(())
}

///|
/// Stop keeps the container and its filesystem. A missing container is
/// success (already stopped from the caller's point of view).
pub async fn stop_container(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
) -> Result[Unit, EnvFailure] {
  match container_ownership(runner, identity) {
    Ok(Owned(_)) => ()
    Ok(Absent) => return Ok(())
    Ok(Foreign(_)) =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CONFLICT,
          "container labels do not match the environment record; left untouched",
        ),
      )
    Err(error) => return Err(error)
  }
  let stop_argv = match @docker.stop_argv(identity, STOP_TIMEOUT_S) {
    Ok(value) => value
    Err(error) => return Err(env_failure_from_docker(error))
  }
  let result = match (runner.invoke)(stop_argv, STOP_TIMEOUT_S + 10) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if result.exit_code == 0 || missing_container(result) {
    Ok(())
  } else {
    Err(
      docker_failure(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "docker stop failed",
        result,
      ),
    )
  }
}

///|
/// Destroy removes the container, env file, env directory and derived scratch
/// directory. Repeated destroy on a missing container is success.
pub async fn destroy_container(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  env_dir : String,
  scratch_dir : String,
) -> CleanupOutcome {
  let log = StringBuilder()
  let mut ok = true
  let mut remove_scratch = false
  match container_ownership(runner, identity) {
    Ok(Owned(_)) => {
      let result = (runner.invoke)(@docker.rm_argv(identity), REMOVE_TIMEOUT_S)
      match result {
        Ok(value) =>
          if value.exit_code == 0 || missing_container(value) {
            cleanup_line(log, "rm -f: ok")
            remove_scratch = true
          } else {
            ok = false
            cleanup_line(
              log,
              "rm -f: failed exit " + value.exit_code.to_string() + ": " +
              value.stderr,
            )
          }
        Err(error) => {
          ok = false
          cleanup_line(log, "rm -f: " + error.to_string())
        }
      }
    }
    Ok(Absent) => {
      cleanup_line(log, "container: absent")
      remove_scratch = true
    }
    Ok(Foreign(_)) => {
      ok = false
      cleanup_line(log, "container labels do not match; left untouched")
    }
    Err(error) => {
      ok = false
      cleanup_line(log, "container ownership: " + error.to_string())
    }
  }
  match (runner.remove_file)(env_dir + "/env") {
    Ok(_) => cleanup_line(log, "env file: removed")
    Err(error) => {
      ok = false
      cleanup_line(log, "env file: " + error.to_string())
    }
  }
  match (runner.remove_dir)(env_dir) {
    Ok(_) => cleanup_line(log, "env dir: removed")
    Err(error) => {
      ok = false
      cleanup_line(log, "env dir: " + error.to_string())
    }
  }
  if remove_scratch {
    match (runner.remove_dir)(scratch_dir) {
      Ok(_) => cleanup_line(log, "scratch dir: removed")
      Err(error) => {
        ok = false
        cleanup_line(log, "scratch dir: " + error.to_string())
      }
    }
  } else {
    cleanup_line(log, "scratch dir: kept (ownership not confirmed)")
  }
  { ok, log: log.to_string(), }
}

// ---------------------------------------------------------------------------
// Exec and doctor
// ---------------------------------------------------------------------------

///|
pub(all) struct ExecOutput {
  exit_code : Int
  stdout : String
  stderr : String
  timed_out : Bool
}

///|
/// Pick the PID-file marker for one exec. A caller-provided `exec_id` is used
/// only when it already fits the bounded runtime-id alphabet; otherwise a
/// fresh ULID is generated, so an untrusted id can never shape a container
/// path.
fn exec_marker(exec_id : String) -> String {
  if exec_id != "" && @docker.is_valid_runtime_id(exec_id) {
    exec_id
  } else {
    @contracts.new_id("ex", @async.now())
  }
}

///|
/// TERM→KILL the container-side process group of one wrapped exec and verify
/// it is gone. `Ok` means the group was signalled and is no longer
/// observable; `Err` means termination could not be confirmed and the caller
/// must not report the exec as successful.
async fn terminate_container_exec(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  marker : String,
) -> Result[Unit, EnvFailure] {
  let argv = match @docker.exec_terminate_argv(identity, marker) {
    Ok(value) => value
    Err(error) => return Err(env_failure_from_docker(error))
  }
  let result = match (runner.invoke)(argv, 10) {
    Ok(value) => value
    Err(error) =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_TIMEOUT,
          "exec termination could not be sent to the container",
        ).with_detail(error.to_string()),
      )
  }
  if result.exit_code == 0 {
    Ok(())
  } else {
    Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_TIMEOUT,
        "exec process group termination could not be confirmed",
      ).with_detail(result.stderr),
    )
  }
}

///|
/// Execute an argv inside the container. This is the `environment.exec` path:
/// no shell string, no environment values in argv. The command runs in its own
/// container-side process group (fixed `setsid` wrapper + PID file), so a
/// timeout or cancellation sends TERM→KILL to the whole group and never
/// leaves a detached command mutating the bind-mounted workspace.
pub async fn exec_in_container(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  argv : Array[String],
  workdir : String,
  timeout_s : Int,
  exec_id~ : String = "",
) -> Result[ExecOutput, EnvFailure] {
  let inspect = match container_ownership(runner, identity) {
    Ok(Owned(value)) => value
    Ok(Absent) =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_ORPHAN_SUSPECTED,
          "environment container is missing; run environment.doctor",
        ),
      )
    Ok(Foreign(_)) =>
      return Err(
        EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CONFLICT,
          "container labels do not match the environment record; left untouched",
        ),
      )
    Err(error) => return Err(error)
  }
  if !inspect.running {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_CONFLICT,
        "environment container is not running",
      ),
    )
  }
  let marker = exec_marker(exec_id)
  let docker_argv = match
    @docker.exec_wrapped_argv(identity, argv, marker, workdir=workdir) {
    Ok(value) => value
    Err(error) => return Err(env_failure_from_docker(error))
  }
  let attempt = @async.handle_cancellation(
    async fn() -> Result[DockerOutput, EnvFailure] {
      (runner.invoke)(docker_argv, timeout_s)
    },
  )
  match attempt {
    Some(Ok(result)) =>
      Ok({
        exit_code: result.exit_code,
        stdout: result.stdout,
        stderr: result.stderr,
        timed_out: false,
      })
    Some(Err(error)) =>
      if error.code == @contracts.ENVIRONMENT_ERR_TIMEOUT {
        match terminate_container_exec(runner, identity, marker) {
          Ok(_) =>
            Ok({
              exit_code: -1,
              stdout: "",
              stderr: "",
              timed_out: true,
            })
          Err(termination) =>
            Err(
              EnvFailure::new(
                @contracts.ENVIRONMENT_ERR_TIMEOUT,
                "exec timed out and its process group could not be confirmed terminated",
              ).with_detail(termination.to_string()),
            )
        }
      } else {
        Err(error)
      }
    None => {
      // The owning task was cancelled. Termination is protected so the
      // container-side command cannot keep running after the API reports a
      // cancellation. A cancelled exec never returns a successful result.
      let termination : Ref[Result[Unit, EnvFailure]] = Ref(Ok(()))
      @async.protect_from_cancel(async fn() {
        termination.val = terminate_container_exec(runner, identity, marker)
      })
      match termination.val {
        Ok(_) =>
          Err(
            EnvFailure::new(
              @contracts.ENVIRONMENT_ERR_TIMEOUT,
              "exec cancelled",
            ),
          )
        Err(error) =>
          Err(
            EnvFailure::new(
              @contracts.ENVIRONMENT_ERR_TIMEOUT,
              "exec cancelled and its process group could not be confirmed terminated",
            ).with_detail(error.to_string()),
          )
      }
    }
  }
}

///|
/// Owner-declared shell command for Run and terminal dispatch. Run commands
/// already exist as shell strings in A1; this path is internal and never
/// exposed as `environment.exec`.
pub async fn shell_in_container(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  command : String,
  workdir : String,
  timeout_s : Int,
) -> Result[ExecOutput, EnvFailure] {
  if command.trim() == "" {
    return Err(
      EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_INVALID,
        "command is empty",
      ),
    )
  }
  exec_in_container(
    runner,
    identity,
    ["sh", "-c", command],
    workdir,
    timeout_s,
  )
}

///|
pub async fn doctor_container(
  runner : DockerRunner,
  record : @contracts.EnvironmentRecord,
  identity : @docker.EnvironmentIdentity,
  recipe : @recipes.Recipe?,
  observed_at : String,
) -> @contracts.EnvironmentDoctorReport {
  let checks : Array[@contracts.EnvironmentDoctorCheck] = []
  let mut healthy = true
  let daemon = (runner.invoke)(["info", "--format", "{{json .}}"], 30)
  match daemon {
    Ok(result) =>
      if result.exit_code == 0 {
        checks.push({
          name: "daemon",
          ok: true,
          detail: "docker daemon reachable",
        })
      } else {
        healthy = false
        checks.push({
          name: "daemon",
          ok: false,
          detail: @contracts.redact_secrets(result.stderr),
        })
      }
    Err(error) => {
      healthy = false
      checks.push({
        name: "daemon",
        ok: false,
        detail: error.to_string(),
      })
    }
  }
  match inspect_container(runner, identity) {
    Ok(Some(inspect)) => {
      checks.push({
        name: "container",
        ok: true,
        detail: "container " + @docker.container_name(identity) + " exists",
      })
      let labels_ok = @docker.inspect_matches_identity(inspect, identity)
      checks.push({
        name: "labels",
        ok: labels_ok,
        detail: if labels_ok {
          "managed labels match"
        } else {
          "managed labels do not match the record"
        },
      })
      if !labels_ok {
        healthy = false
      }
      checks.push({
        name: "running",
        ok: inspect.running,
        detail: "status=" + inspect.status,
      })
      if !inspect.running {
        healthy = false
      }
      checks.push({
        name: "mounts",
        ok: inspect.mounts.length() > 0,
        detail: inspect.mounts.length().to_string() + " mount(s)",
      })
      match recipe {
        Some(value) =>
          match value.doctor {
            Some(doctor) => {
              let argv = match
                @docker.exec_argv(
                  identity,
                  doctor.argv,
                  workdir=record.workdir,
                ) {
                Ok(value) => value
                Err(error) => {
                  healthy = false
                  checks.push({
                    name: "recipe_doctor",
                    ok: false,
                    detail: env_failure_from_docker(error).to_string(),
                  })
                  return doctor_report(
                    record,
                    healthy,
                    checks,
                    observed_at,
                  )
                }
              }
              let budget = if doctor.timeout_s < 1 {
                30
              } else if doctor.timeout_s > 300 {
                300
              } else {
                doctor.timeout_s
              }
              match (runner.invoke)(argv, budget) {
                Ok(result) => {
                  let ok = result.exit_code == 0
                  if !ok {
                    healthy = false
                  }
                  checks.push({
                    name: "recipe_doctor",
                    ok,
                    detail: @contracts.redact_secrets(
                      result.stdout + result.stderr,
                    ),
                  })
                }
                Err(error) => {
                  healthy = false
                  checks.push({
                    name: "recipe_doctor",
                    ok: false,
                    detail: error.to_string(),
                  })
                }
              }
            }
            None => {
              checks.push({
                name: "recipe_doctor",
                ok: true,
                detail: "recipe declares no doctor command",
              })
            }
          }
        None => {
          checks.push({
            name: "recipe",
            ok: false,
            detail: "recipe is not available for verification",
          })
          healthy = false
        }
      }
    }
    Ok(None) => {
      healthy = false
      checks.push({
        name: "container",
        ok: false,
        detail: "container " + @docker.container_name(identity) +
        " does not exist",
      })
    }
    Err(error) => {
      healthy = false
      checks.push({
        name: "container",
        ok: false,
        detail: error.to_string(),
      })
    }
  }
  doctor_report(record, healthy, checks, observed_at)
}

///|
fn doctor_report(
  record : @contracts.EnvironmentRecord,
  healthy : Bool,
  checks : Array[@contracts.EnvironmentDoctorCheck],
  observed_at : String,
) -> @contracts.EnvironmentDoctorReport {
  let guidance = if healthy {
    "environment is healthy; managed containers only"
  } else {
    "inspect only monexus-env-" + record.id +
    "; do not delete unowned containers or run docker system prune"
  }
  {
    environment_id: record.id,
    container_name: record.container_name,
    machine_id: record.machine_id,
    backend: record.backend,
    state: record.state,
    healthy,
    checks,
    guidance,
    observed_at,
  }
}
