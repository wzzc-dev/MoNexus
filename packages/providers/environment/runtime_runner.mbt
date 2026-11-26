///|
/// Runtime-node runner for environment lifecycle (ADR-0013 §5, A2.2).
///
/// The lifecycle engine is unchanged: it still builds the same docker argv,
/// uses the same env-file hand-off and the same cleanup matrix. This module
/// only routes the runner's five operations to a paired runtime node through
/// `runtime.exec.*`, `runtime.fs.*` and `runtime.pty.*`. The primary remains
/// the sole authority for records, Decisions and audit; the node never sees
/// an environment table or approval state.
///
/// Every operation carries the A2.1 approval Decision id (empty for the
/// primary's own authorization); the host adapter mints one A1.3b grant per
/// invocation from it.

///|
/// The runtime node's operations. Paths are absolute on the node; the host
/// adapter translates them to rooted-relative `runtime.fs.*` requests under
/// `~/.monexus/environments`. Arguments are `(argv, timeout_s, decision_id)`.
pub(all) struct RuntimeOps {
  invoke : async (Array[String], Int, String) -> Result[
    DockerOutput,
    EnvFailure,
  ]
  make_dir : async (String, String) -> Result[Unit, EnvFailure]
  write_env : async (
    String,
    Array[@docker.EnvironmentVariable],
    String,
  ) -> Result[Unit, EnvFailure]
  remove_file : async (String, String) -> Result[Unit, EnvFailure]
  remove_dir : async (String, String) -> Result[Unit, EnvFailure]
  terminal : async (
    Array[String],
    Int32,
    Int32,
    @aqueue.Queue[@workspace.TerminalInput],
    @aqueue.Queue[@workspace.TerminalEvent],
    String,
  ) -> Unit
}

///|
/// Build a `DockerRunner` whose operations execute on a paired runtime node.
/// `home` is the node home reported by `runtime.probe`; the lifecycle's
/// `environment_dir` therefore stays `~/.monexus/environments/<id>`.
pub async fn runtime_runner(
  machine_id~ : String,
  home~ : String,
  ops~ : RuntimeOps,
) -> DockerRunner {
  let authorization : Ref[String] = Ref("")
  let invoke : DockerInvoke = async fn(argv, timeout_s) {
    (ops.invoke)(argv, timeout_s, authorization.val)
  }
  let make_dir : PathOp = async fn(path) {
    (ops.make_dir)(path, authorization.val)
  }
  let write_secret : WriteSecretOp = async fn(dir, variables) {
    (ops.write_env)(dir, variables, authorization.val)
  }
  let remove_file : PathOp = async fn(path) {
    (ops.remove_file)(path, authorization.val)
  }
  let remove_dir : PathOp = async fn(path) {
    (ops.remove_dir)(path, authorization.val)
  }
  let terminal : RuntimeTerminalOp = async fn(argv, rows, cols, input, output) {
    (ops.terminal)(argv, rows, cols, input, output, authorization.val)
  }
  {
    machine_id,
    remote: true,
    home,
    target: None,
    invoke,
    make_dir,
    write_secret,
    remove_file,
    remove_dir,
    runtime: true,
    authorization: Some(authorization),
    terminal: Some(terminal),
  }
}
