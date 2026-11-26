///|
/// Operation kinds the remote runtime classifies before executing anything.
/// `Unknown` is kept rather than defaulting to `Exec` so a newer transport
/// method cannot silently inherit exec's low-risk rules.
pub(all) enum PolicyOperation {
  Exec
  Pty
  FsRead
  FsWrite
  FsDelete
  GitRead
  GitWrite
  /// Continuation of an already-running exec/PTY session (cancel, input,
  /// resize, close). It mutates nothing new but is still evaluated and
  /// audited as a mutation; it never silently bypasses the classifier.
  Control
  Unknown(String)
}

///|
pub fn PolicyOperation::from_label(label : String) -> PolicyOperation {
  match label.to_lower() {
    "exec" => Exec
    "pty" => Pty
    "fs.read" => FsRead
    "fs.write" => FsWrite
    "fs.delete" => FsDelete
    "git.read" => GitRead
    "git.write" => GitWrite
    "control" => Control
    other => Unknown(other)
  }
}

///|
pub fn PolicyOperation::label(self : PolicyOperation) -> String {
  match self {
    Exec => "exec"
    Pty => "pty"
    FsRead => "fs.read"
    FsWrite => "fs.write"
    FsDelete => "fs.delete"
    GitRead => "git.read"
    GitWrite => "git.write"
    Control => "control"
    Unknown(raw) => raw
  }
}

///|
/// Whether the operation is intrinsically read-only. `Exec` depends on argv
/// and is resolved by the classifier instead.
pub fn PolicyOperation::is_read_only(self : PolicyOperation) -> Bool {
  match self {
    FsRead => true
    GitRead => true
    _ => false
  }
}

///|
pub const MAX_ARGV_ITEMS : Int = 256

///|
pub const MAX_ARG_LENGTH : Int = 8_192

///|
pub const MAX_ENV_NAMES : Int = 64

///|
pub const MAX_PATH_LENGTH : Int = 4_096

///|
/// One execution request as the runtime sees it. The digest covers every
/// execution-affecting value: argv, the resolved absolute cwd, environment
/// names *and values*, stdin, fs.write content and git worktree flags. The
/// canonical text is hashed and never sent or logged; `PolicyDecision` and the
/// audit rings carry only the digest, and the host Decision detail redacts the
/// values before display.
pub(all) struct ExecutionRequest {
  operation : PolicyOperation
  argv : Array[String]
  cwd : String
  workspace_root : String
  env_names : Array[String]
  env_values : Array[(String, String)]
  stdin : String
  content : String
  git_force : Bool
  git_expected_head : String
  git_expected_branch : String
}

///|
pub fn ExecutionRequest::new(
  operation~ : PolicyOperation,
  argv~ : Array[String],
  cwd~ : String,
  workspace_root~ : String,
  env_names~ : Array[String] = [],
  env_values~ : Array[(String, String)] = [],
  stdin~ : String = "",
  content~ : String = "",
  git_force~ : Bool = false,
  git_expected_head~ : String = "",
  git_expected_branch~ : String = "",
) -> ExecutionRequest {
  {
    operation,
    argv,
    cwd,
    workspace_root,
    env_names: sorted_unique(env_names),
    env_values: sorted_pairs_unique(env_values),
    stdin,
    content,
    git_force,
    git_expected_head,
    git_expected_branch,
  }
}

// ---------------------------------------------------------------------------
// Lexical path containment
// ---------------------------------------------------------------------------

///|
/// Normalize an absolute POSIX path lexically: collapse `//`, drop `.`, and
/// resolve `..`. Returns None when the path is relative, empty, or climbs
/// above `/`. Symlinks and mount escapes are intentionally out of scope here;
/// the exec layer performs the real-path check (ADR-0012 §6).
pub fn normalize_abs_path(path : String) -> String? {
  if !path.has_prefix("/") || path.length() > MAX_PATH_LENGTH {
    return None
  }
  for ch in path {
    if ch.to_int() == 0 {
      return None
    }
  }
  let parts : Array[String] = []
  for segment in path.split("/") {
    let part = segment.to_owned()
    if part == "" || part == "." {
      continue
    }
    if part == ".." {
      if parts.length() == 0 {
        return None
      }
      ignore(parts.pop())
    } else {
      parts.push(part)
    }
  }
  if parts.length() == 0 {
    Some("/")
  } else {
    Some("/" + parts.join("/"))
  }
}

///|
/// Lexical containment: normalized `path` equals `root` or sits below it.
/// Both must be absolute; malformed input is not contained.
pub fn path_within_root(root : String, path : String) -> Bool {
  let normalized_root = match normalize_abs_path(root) {
    Some(value) => value
    None => return false
  }
  let normalized_path = match normalize_abs_path(path) {
    Some(value) => value
    None => return false
  }
  if normalized_root == "/" {
    return true
  }
  normalized_path == normalized_root ||
  normalized_path.has_prefix(normalized_root + "/")
}

///|
/// Whether an argv item looks like a filesystem path. Absolute paths and
/// anything containing a `..` component are checked; other relative values
/// stay under the already-contained cwd.
fn looks_like_path(item : String) -> Bool {
  item.has_prefix("/") ||
  item == ".." ||
  item.has_prefix("../") ||
  item.has_suffix("/..") ||
  item.contains("/../")
}

///|
/// Whether this argv is a container-engine invocation
/// (`docker`/`podman`/`nerdctl`/`containerd` as argv[0]).
///
/// ADR-0013 §5 executes environment recipes through exactly this channel. The
/// built-in classifier always classifies a container-engine argv as High, so
/// every such request needs a primary-minted grant bound to the exact digest;
/// it can never be silently low-risk. Its path arguments name node-owned
/// roots outside the workspace (the environment directory, the scratch
/// directory, container bind sources), which is why the workspace-containment
/// loop below does not apply. Structural checks, cwd containment and the
/// classifier itself are unchanged, and an argv whose argv[0] is a shell is
/// not exempt.
fn is_container_engine_argv(argv : Array[String]) -> Bool {
  if argv.length() == 0 {
    return false
  }
  let engine = command_basename(argv[0])
  engine == "docker" ||
  engine == "podman" ||
  engine == "nerdctl" ||
  engine == "containerd"
}

// ---------------------------------------------------------------------------
// Request validation
// ---------------------------------------------------------------------------

///|
/// Structural validation that does not depend on a snapshot. Any returned
/// reason is safe to show: it never echoes an argv value or an env value.
pub fn ExecutionRequest::validate(self : ExecutionRequest) -> String? {
  let exec_like = match self.operation {
    Exec | Pty => true
    _ => false
  }
  if exec_like && self.argv.length() == 0 {
    return Some("command is empty")
  }
  if self.argv.length() > MAX_ARGV_ITEMS {
    return Some("command has too many arguments")
  }
  for item in self.argv {
    if item.length() > MAX_ARG_LENGTH {
      return Some("command argument is too long")
    }
    for ch in item {
      if ch.to_int() == 0 {
        return Some("command argument contains a NUL byte")
      }
    }
  }
  if self.env_names.length() > MAX_ENV_NAMES {
    return Some("request names too many environment variables")
  }
  for name in self.env_names {
    if name.length() > 64 || !is_env_name(name) {
      return Some("request has an invalid environment variable name")
    }
  }
  if self.env_values.length() > MAX_ENV_NAMES {
    return Some("request carries too many environment values")
  }
  for pair in self.env_values {
    let name = pair.0
    if name.length() > 64 || !is_env_name(name) {
      return Some("request has an invalid environment variable name")
    }
    if pair.1.length() > MAX_ARG_LENGTH {
      return Some("environment value is too long")
    }
  }
  if self.workspace_root.length() > MAX_PATH_LENGTH ||
    self.cwd.length() > MAX_PATH_LENGTH {
    return Some("workspace path is too long")
  }
  let root = match normalize_abs_path(self.workspace_root) {
    Some(value) => value
    None => return Some("workspace root is not an absolute path")
  }
  let cwd = match normalize_abs_path(self.cwd) {
    Some(value) => value
    None => return Some("cwd is not an absolute path")
  }
  if !path_within_root(root, cwd) {
    return Some("cwd escapes the workspace root")
  }
  // Executable path (argv[0]) is a machine path, not workspace data. Every
  // later argument that looks like a path must stay under the workspace root;
  // otherwise a read-only command could read or write outside it. A container
  // engine is the environment execution channel (ADR-0013 §5): its arguments
  // deliberately name node-owned roots outside the workspace, and the built-in
  // High classification plus the digest-bound grant are what constrain it.
  if !is_container_engine_argv(self.argv) {
    let mut index = 1
    while index < self.argv.length() {
      let item = self.argv[index]
      if looks_like_path(item) {
        let target = if item.has_prefix("/") {
          item
        } else {
          cwd + "/" + item
        }
        if !path_within_root(root, target) {
          return Some("command path argument escapes the workspace root")
        }
      }
      index = index + 1
    }
  }
  None
}

// ---------------------------------------------------------------------------
// Deterministic command digest
// ---------------------------------------------------------------------------

///|
/// Domain separator for the command digest. Bump the version if the canonical
/// field set ever changes; grants issued for one version never match another.
pub const COMMAND_DIGEST_PREFIX : String = "sha256:"

///|
pub const COMMAND_DIGEST_DOMAIN : String = "monexus.exec.v2"

///|
/// Canonical serialization used by the digest:
///
/// ```text
/// monexus.exec.v2\n
/// {"argv":[...],"content":"...","cwd":"...","env":[...],"env_values":[...],
///  "git_expected_branch":"...","git_expected_head":"...","git_force":false,
///  "operation":"...","stdin":"...","workspace_root":"..."}
/// ```
///
/// `argv` keeps order (it is semantically significant). `env` is the sorted,
/// de-duplicated list of environment names; `env_values` is the sorted list of
/// explicit name/value pairs. `stdin` and `content` bind script and file
/// payloads. The git fields bind worktree force/expected-head parameters.
/// Paths and strings are JSON escaped as defined in `canonical.mbt`.
pub fn ExecutionRequest::canonical(self : ExecutionRequest) -> String {
  COMMAND_DIGEST_DOMAIN + "\n" + "{" +
  "\"argv\":" + canonical_string_array(self.argv) + "," +
  "\"content\":" + canonical_quote(self.content) + "," +
  "\"cwd\":" + canonical_quote(self.cwd) + "," +
  "\"env\":" + canonical_string_array(sorted_unique(self.env_names)) + "," +
  "\"env_values\":" + canonical_pairs(sorted_pairs_unique(self.env_values)) + "," +
  "\"git_expected_branch\":" + canonical_quote(self.git_expected_branch) + "," +
  "\"git_expected_head\":" + canonical_quote(self.git_expected_head) + "," +
  "\"git_force\":" + canonical_bool(self.git_force) + "," +
  "\"operation\":" + canonical_quote(self.operation.label()) + "," +
  "\"stdin\":" + canonical_quote(self.stdin) + "," +
  "\"workspace_root\":" + canonical_quote(self.workspace_root) +
  "}"
}

///|
/// Stable command digest: `sha256:` plus the lowercase hex SHA-256 of the
/// canonical serialization above. It is independent of run id, policy
/// version, timestamps and caller ordering of env names.
pub fn ExecutionRequest::digest(self : ExecutionRequest) -> String {
  COMMAND_DIGEST_PREFIX + sha256_hex(self.canonical())
}
