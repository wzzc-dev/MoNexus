///|
/// Runtime method contracts (A1.2b).
///
/// The paired runtime transport reserves `runtime.pair`, `runtime.hello`,
/// `runtime.heartbeat`, `runtime.rotate`, `runtime.probe`, `runtime.bye`,
/// `runtime.event`, `runtime.ack`, `runtime.drain` and `runtime.replay_gap`.
/// The methods below are the application layer layered on top: the primary
/// sends them over the duplex session channel, the node dispatches them to the
/// runtime execution core (`monexus/runtime`).
///
/// Every mutating method takes `client_request_id` in `params`. A retry with
/// the same id returns the recorded result without executing again, both at
/// the primary (durable handler cache) and at the node (bounded in-memory
/// cache plus the runtime's own durable `(client_request_id -> run_id)`
/// mapping). Read methods are idempotent by construction.

///|
pub const METHOD_RUNTIME_EXEC_START : String = "runtime.exec.start"

///|
pub const METHOD_RUNTIME_EXEC_CANCEL : String = "runtime.exec.cancel"

///|
pub const METHOD_RUNTIME_EXEC_STATUS : String = "runtime.exec.status"

///|
/// Read a bounded slice of one stream log (`stdout`/`stderr`) of an exec run.
/// The environment backend needs the command's output to parse `docker
/// inspect` and to report hook output; a run's status alone carries only the
/// exit code. This is a read method over the node-owned log file, with the
/// same offset/eof/log_bytes shape as `runtime.git.read_output`.
pub const METHOD_RUNTIME_EXEC_READ : String = "runtime.exec.read"

///|
pub const METHOD_RUNTIME_FS_READ : String = "runtime.fs.read"

///|
pub const METHOD_RUNTIME_FS_WRITE : String = "runtime.fs.write"

///|
pub const METHOD_RUNTIME_FS_LIST : String = "runtime.fs.list"

///|
pub const METHOD_RUNTIME_FS_STAT : String = "runtime.fs.stat"

///|
/// Create one directory under a selected rooted filesystem (A2.2). The
/// environment backend creates `~/.monexus/environments/<id>/` on the node;
/// `runtime.fs.write` cannot create a directory, and the env-file parent must
/// be 0700 before the secret is written.
pub const METHOD_RUNTIME_FS_MKDIR : String = "runtime.fs.mkdir"

///|
/// Remove one file or directory under a selected rooted filesystem (A2.2).
/// The environment backend removes the env-file hand-off and temp directory
/// after `destroy`; the node enforces root containment itself.
pub const METHOD_RUNTIME_FS_REMOVE : String = "runtime.fs.remove"

///|
/// Selector for the filesystem root of `fs.read/write/list/stat/mkdir/
/// remove`. `workspace` is the default and preserves the A1.2 behavior; the
/// node-owned `~/.monexus/environments` root is the only additional root
/// (A2.2), so environment files never land in a workspace.
pub const RUNTIME_FS_ROOT_WORKSPACE : String = "workspace"

///|
pub const RUNTIME_FS_ROOT_ENVIRONMENTS : String = "environments"

///|
pub const METHOD_RUNTIME_PTY_OPEN : String = "runtime.pty.open"

///|
pub const METHOD_RUNTIME_PTY_INPUT : String = "runtime.pty.input"

///|
pub const METHOD_RUNTIME_PTY_RESIZE : String = "runtime.pty.resize"

///|
pub const METHOD_RUNTIME_PTY_CLOSE : String = "runtime.pty.close"

///|
pub const METHOD_RUNTIME_PTY_STATUS : String = "runtime.pty.status"

///|
/// Streaming process methods (A1.4). A process is a long-lived argv-only child
/// with an open stdin, used by the host's AgentRuntime to run an ACP adapter on
/// a paired runtime. Unlike `exec.start` there is no implicit timeout and no
/// end-of-run log path: output is read by absolute byte offset through
/// `stdout`/`stderr`, and stdin is written incrementally through `stdin`.
/// `run_id` is the stable identity across reconnects; `client_request_id`
/// makes `start` idempotent.
pub const METHOD_RUNTIME_PROCESS_START : String = "runtime.process.start"

///|
pub const METHOD_RUNTIME_PROCESS_STDIN : String = "runtime.process.stdin"

///|
pub const METHOD_RUNTIME_PROCESS_STDOUT : String = "runtime.process.stdout"

///|
pub const METHOD_RUNTIME_PROCESS_STDERR : String = "runtime.process.stderr"

///|
pub const METHOD_RUNTIME_PROCESS_EXIT : String = "runtime.process.exit"

///|
pub const METHOD_RUNTIME_PROCESS_CANCEL : String = "runtime.process.cancel"

///|
pub const METHOD_RUNTIME_GIT_STATUS : String = "runtime.git.status"

///|
pub const METHOD_RUNTIME_GIT_DIFF : String = "runtime.git.diff"

///|
pub const METHOD_RUNTIME_GIT_LOG : String = "runtime.git.log"

///|
pub const METHOD_RUNTIME_GIT_SHOW : String = "runtime.git.show"

///|
pub const METHOD_RUNTIME_GIT_BRANCHES : String = "runtime.git.branches"

///|
pub const METHOD_RUNTIME_GIT_BRANCH_CREATE : String = "runtime.git.branch_create"

///|
pub const METHOD_RUNTIME_GIT_CHECKOUT : String = "runtime.git.checkout"

///|
pub const METHOD_RUNTIME_GIT_WORKTREES : String = "runtime.git.worktrees"

///|
pub const METHOD_RUNTIME_GIT_WORKTREE_ADD : String = "runtime.git.worktree_add"

///|
pub const METHOD_RUNTIME_GIT_WORKTREE_REMOVE : String =
  "runtime.git.worktree_remove"

///|
pub const METHOD_RUNTIME_GIT_READ_OUTPUT : String = "runtime.git.read_output"

///|
/// Every application method the node registers. A1.3b (policy) and A1.4
/// (remote ACP) dispatch through these names; they must not drift.
pub fn runtime_application_methods() -> Array[String] {
  [
    METHOD_RUNTIME_EXEC_START,
    METHOD_RUNTIME_EXEC_CANCEL,
    METHOD_RUNTIME_EXEC_STATUS,
    METHOD_RUNTIME_EXEC_READ,
    METHOD_RUNTIME_FS_READ,
    METHOD_RUNTIME_FS_WRITE,
    METHOD_RUNTIME_FS_LIST,
    METHOD_RUNTIME_FS_STAT,
    METHOD_RUNTIME_FS_MKDIR,
    METHOD_RUNTIME_FS_REMOVE,
    METHOD_RUNTIME_PTY_OPEN,
    METHOD_RUNTIME_PTY_INPUT,
    METHOD_RUNTIME_PTY_RESIZE,
    METHOD_RUNTIME_PTY_CLOSE,
    METHOD_RUNTIME_PTY_STATUS,
    METHOD_RUNTIME_PROCESS_START,
    METHOD_RUNTIME_PROCESS_STDIN,
    METHOD_RUNTIME_PROCESS_STDOUT,
    METHOD_RUNTIME_PROCESS_STDERR,
    METHOD_RUNTIME_PROCESS_EXIT,
    METHOD_RUNTIME_PROCESS_CANCEL,
    METHOD_RUNTIME_GIT_STATUS,
    METHOD_RUNTIME_GIT_DIFF,
    METHOD_RUNTIME_GIT_LOG,
    METHOD_RUNTIME_GIT_SHOW,
    METHOD_RUNTIME_GIT_BRANCHES,
    METHOD_RUNTIME_GIT_BRANCH_CREATE,
    METHOD_RUNTIME_GIT_CHECKOUT,
    METHOD_RUNTIME_GIT_WORKTREES,
    METHOD_RUNTIME_GIT_WORKTREE_ADD,
    METHOD_RUNTIME_GIT_WORKTREE_REMOVE,
    METHOD_RUNTIME_GIT_READ_OUTPUT,
    METHOD_RUNTIME_SKILL_MIRROR,
    METHOD_RUNTIME_SKILL_LIST,
    METHOD_RUNTIME_SKILL_INVOKE,
    METHOD_RUNTIME_SKILL_GC,
  ]
}

///|
/// Methods that change node state and therefore require a policy snapshot
/// (A1.3b). Reads (status/list/stat/read/exec.read/diff/log/show/branches/
/// worktrees/read_output) are allowed with no snapshot; writes, exec starts,
/// directory creation/removal, PTY input/resize/close and git branch/worktree
/// mutations fail closed.
pub fn runtime_method_mutates(method : String) -> Bool {
  method == METHOD_RUNTIME_EXEC_START ||
  method == METHOD_RUNTIME_EXEC_CANCEL ||
  method == METHOD_RUNTIME_FS_WRITE ||
  method == METHOD_RUNTIME_FS_MKDIR ||
  method == METHOD_RUNTIME_FS_REMOVE ||
  method == METHOD_RUNTIME_PTY_OPEN ||
  method == METHOD_RUNTIME_PTY_INPUT ||
  method == METHOD_RUNTIME_PTY_RESIZE ||
  method == METHOD_RUNTIME_PTY_CLOSE ||
  method == METHOD_RUNTIME_PROCESS_START ||
  method == METHOD_RUNTIME_PROCESS_STDIN ||
  method == METHOD_RUNTIME_PROCESS_CANCEL ||
  method == METHOD_RUNTIME_GIT_BRANCH_CREATE ||
  method == METHOD_RUNTIME_GIT_CHECKOUT ||
  method == METHOD_RUNTIME_GIT_WORKTREE_ADD ||
  method == METHOD_RUNTIME_GIT_WORKTREE_REMOVE ||
  method == METHOD_RUNTIME_SKILL_MIRROR ||
  method == METHOD_RUNTIME_SKILL_INVOKE ||
  method == METHOD_RUNTIME_SKILL_GC
}
