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
/// One execution request as the runtime sees it. It deliberately has no env
/// *values* and no secret material: only names are classified and digested.
pub(all) struct ExecutionRequest {
  operation : PolicyOperation
  argv : Array[String]
  cwd : String
  workspace_root : String
  env_names : Array[String]
}

///|
pub fn ExecutionRequest::new(
  operation~ : PolicyOperation,
  argv~ : Array[String],
  cwd~ : String,
  workspace_root~ : String,
  env_names~ : Array[String] = [],
) -> ExecutionRequest {
  {
    operation,
    argv,
    cwd,
    workspace_root,
    env_names: sorted_unique(env_names),
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
  // otherwise a read-only command could read or write outside it.
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
pub const COMMAND_DIGEST_DOMAIN : String = "monexus.exec.v1"

///|
/// Canonical serialization used by the digest:
///
/// ```text
/// monexus.exec.v1\n
/// {"argv":[...],"cwd":"...","env":[...],"operation":"...","workspace_root":"..."}
/// ```
///
/// `argv` keeps order (it is semantically significant). `env` is the sorted,
/// de-duplicated list of environment *names*; values never enter this string.
/// `operation` is the lower-case operation label. Paths and strings are JSON
/// escaped as defined in `canonical.mbt`.
pub fn ExecutionRequest::canonical(self : ExecutionRequest) -> String {
  COMMAND_DIGEST_DOMAIN + "\n" + "{" +
  "\"argv\":" + canonical_string_array(self.argv) + "," +
  "\"cwd\":" + canonical_quote(self.cwd) + "," +
  "\"env\":" + canonical_string_array(sorted_unique(self.env_names)) + "," +
  "\"operation\":" + canonical_quote(self.operation.label()) + "," +
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
