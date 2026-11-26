///|
/// Node dispatch: `runtime.exec|fs|pty|git.*` onto the runtime execution core.
///
/// Every request is checked against the policy gate before the idempotency
/// cache, so a revoked/fail-closed policy cannot be bypassed by replaying a
/// cached mutating request. Mutating requests carry `client_request_id`;
/// a duplicate returns the cached result and never re-executes. Results are
/// bounded so no response can exceed the 64 KiB transport frame.

///|
pub const MAX_FS_READ_CHARS : Int = 16_384

///|
pub const MAX_FS_READ_FILE_BYTES : Int64 = 1_048_576L

///|
pub const MAX_FS_WRITE_CHARS : Int = 24_576

///|
pub const MAX_PTY_INPUT_CHARS : Int = 8_192

///|
pub const MAX_LIST_ENTRIES : Int = 512

///|
pub const MAX_RUNS_PER_STATUS : Int = 256

///|
pub const MAX_GIT_OUTPUT_CHARS : Int = 32_768

///|
pub const MAX_EXEC_OUTPUT_CHARS : Int = 32_768

// ---------------------------------------------------------------------------
// Rooted environment filesystem (A2.2)
// ---------------------------------------------------------------------------

///|
/// The `root` selector carried by fs requests. An absent value means the
/// workspace, preserving the A1.2 contract; the only other value is the
/// node-owned environment root.
fn fs_root_selector(
  params : Map[String, @json.Json],
) -> Result[String, @contracts.RpcError] {
  let root = optional_string(params, "root")
  if root == "" || root == @contracts.RUNTIME_FS_ROOT_WORKSPACE {
    return Ok(@contracts.RUNTIME_FS_ROOT_WORKSPACE)
  }
  if root == @contracts.RUNTIME_FS_ROOT_ENVIRONMENTS {
    return Ok(@contracts.RUNTIME_FS_ROOT_ENVIRONMENTS)
  }
  Err(invalid_params("unknown filesystem root selector"))
}

///|
/// Resolve the rooted directory named by the selector. A node without a home
/// has no environment root and refuses the request instead of guessing.
async fn NodeHost::selected_root(
  self : NodeHost,
  selector : String,
) -> Result[@runtime.RootedDir, @contracts.RpcError] {
  if selector == @contracts.RUNTIME_FS_ROOT_ENVIRONMENTS {
    match self.environments {
      Some(value) => Ok(value)
      None =>
        return Err(
          @contracts.RpcError::new(
            @transport.ERR_PATH_DENIED,
            "this runtime node has no environment root",
          ),
        )
    }
  } else {
    Ok(self.workspace)
  }
}

///|
fn real_within_root(root : String, real : String) -> Bool {
  real == root || real.has_prefix(root + "/")
}

///|
/// Create a directory at a rooted-relative path. Every existing component
/// must resolve under the real root; a missing component is created 0700.
/// Symlinks are followed only when their real target stays inside the root.
async fn rooted_mkdir(
  root : @runtime.RootedDir,
  relative : String,
  recursive : Bool,
) -> Result[Unit, String] {
  let normalized = match @runtime.normalize_rooted_path(relative) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if normalized == "" {
    return Err("path is the root directory")
  }
  let root_path = root.root()
  let mut current = root_path
  let parts = normalized.split("/")
  let mut index = 0
  for part in parts {
    index = index + 1
    current = current + "/" + part.to_owned()
    let exists = @fs.exists(current) catch { _ => false }
    if exists {
      let real = @fs.realpath(current) catch {
        error => return Err("cannot resolve path: " + error.to_string())
      }
      if !real_within_root(root_path, real) {
        return Err("path escapes the root after resolution")
      }
      let kind = @fs.kind(real, follow_symlink=true) catch {
        error => return Err("cannot stat path: " + error.to_string())
      }
      guard kind is @fs.FileKind::Directory else {
        return Err("path is not a directory")
      }
      current = real
    } else {
      if !recursive && index < parts.length() {
        return Err("parent directory does not exist")
      }
      // Do not follow a symlink in the final component: create it directly.
      @fs.mkdir(current, permission=0o700, recursive=false, allow_exist=false) catch {
        error => {
          // A concurrent creator may have won the race; only accept it if the
          // resolved path is a directory inside the root.
          let real = @fs.realpath(current) catch {
            _ => return Err("cannot create directory: " + error.to_string())
          }
          if !real_within_root(root_path, real) {
            return Err("path escapes the root after resolution")
          }
          let kind = @fs.kind(real, follow_symlink=true) catch {
            _ => return Err("cannot create directory: " + error.to_string())
          }
          guard kind is @fs.FileKind::Directory else {
            return Err("cannot create directory: " + error.to_string())
          }
          current = real
        }
      }
      let real = @fs.realpath(current) catch {
        error => return Err("cannot resolve directory: " + error.to_string())
      }
      if !real_within_root(root_path, real) {
        return Err("path escapes the root after resolution")
      }
      current = real
    }
  }
  @fs.chmod(current, 0o700) catch { _ => () }
  Ok(())
}

///|
/// Remove one file, symlink or directory at a rooted-relative path. The path
/// itself and its parent must resolve under the real root; the root itself is
/// never removable. Missing entries are a success (the operation is
/// idempotent), matching the local/SSH remove semantics.
async fn rooted_remove(
  root : @runtime.RootedDir,
  relative : String,
  recursive : Bool,
) -> Result[Unit, String] {
  let normalized = match @runtime.normalize_rooted_path(relative) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  if normalized == "" {
    return Err("path is the root directory")
  }
  let root_path = root.root()
  let parts : Array[String] = []
  for part in normalized.split("/") {
    parts.push(part.to_owned())
  }
  let name = parts[parts.length() - 1]
  let parent_rel : Array[String] = []
  for index in 0..<(parts.length() - 1) {
    parent_rel.push(parts[index])
  }
  // Missing entries are a success, including when their parent is already
  // gone (destroy removes the environment directory before the scratch
  // directory nested inside it). No removal happens on a missing path.
  let lexical = root_path + "/" + normalized
  let exists = @fs.exists(lexical) catch { _ => false }
  if !exists {
    return Ok(())
  }
  let parent = if parent_rel.length() == 0 {
    root_path
  } else {
    let lexical_parent = root_path + "/" + parent_rel.join("/")
    let real = @fs.realpath(lexical_parent) catch {
      error => return Err("cannot resolve parent directory: " + error.to_string())
    }
    if !real_within_root(root_path, real) {
      return Err("path escapes the root after resolution")
    }
    let kind = @fs.kind(real, follow_symlink=true) catch {
      error => return Err("cannot stat parent directory: " + error.to_string())
    }
    guard kind is @fs.FileKind::Directory else {
      return Err("parent path is not a directory")
    }
    real
  }
  let target = parent + "/" + name
  // lstat the final component: a symlink inside the root is removed as a
  // link, never followed.
  let kind = @fs.kind(target, follow_symlink=false) catch {
    error => return Err("cannot stat path: " + error.to_string())
  }
  match kind {
    @fs.FileKind::Directory => {
      let real = @fs.realpath(target) catch {
        error => return Err("cannot resolve directory: " + error.to_string())
      }
      if !real_within_root(root_path, real) {
        return Err("path escapes the root after resolution")
      }
      @fs.rmdir(real, recursive=recursive) catch {
        error => return Err("cannot remove directory: " + error.to_string())
      }
    }
    @fs.FileKind::Regular | @fs.FileKind::SymLink =>
      @fs.remove(target) catch {
        error => return Err("cannot remove file: " + error.to_string())
      }
    _ => return Err("path is not a file or directory")
  }
  let remains = @fs.exists(target) catch { _ => true }
  if remains {
    return Err("path still exists after removal")
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Rooted exec log read (A2.2)
// ---------------------------------------------------------------------------

///|
fn invalid_params(message : String) -> @contracts.RpcError {
  @contracts.RpcError::new(@contracts.ERR_INVALID_PARAMS, message)
}

///|
fn result_too_large(message : String) -> @contracts.RpcError {
  @contracts.RpcError::new(@transport.ERR_RESULT_TOO_LARGE, message)
}

///|
/// Map a rooted-workspace failure. Escapes and absolute paths get the
/// dedicated `path_denied` transport code; everything else is caller-fixable
/// input (missing file, not a regular file, ...).
fn fs_failure(message : String) -> @contracts.RpcError {
  let denied = message.contains("escape") ||
    message.contains("absolute paths") ||
    message.contains(".ssh")
  @contracts.RpcError::new(
    if denied {
      @transport.ERR_PATH_DENIED
    } else {
      @contracts.ERR_INVALID_PARAMS
    },
    message,
  )
}

///|
fn runtime_failure(error : @runtime.RuntimeError) -> @contracts.RpcError {
  // Translate the runtime's stable `kind` onto the transport error codes where
  // A1.2 has a dedicated code; everything else keeps the runtime's code
  // (already drawn from the same JSON-RPC table).
  let code = if error.kind == "path_denied" {
    @transport.ERR_PATH_DENIED
  } else if error.kind == "not_enabled" {
    @contracts.ERR_INVALID_REQUEST
  } else {
    error.code
  }
  @contracts.RpcError::new(
    code,
    error.message,
    data=@contracts.json_object([
      ("kind", @contracts.json_string(error.kind)),
      ("run_seq", @contracts.json_int64(error.run_seq)),
    ]),
  )
}

///|
/// Map a `RuntimeExecutor::start` string failure. Input validation errors are
/// caller-fixable; state failures are host errors. The runtime's own message
/// is already bounded and redacted.
fn start_failure(message : String) -> @contracts.RpcError {
  let invalid = message.contains("required") ||
    message.contains("invalid") ||
    message.contains("argv") ||
    message.contains("must be") ||
    message.contains("exceeds") ||
    message.contains("policy denies") ||
    message.contains("credential") ||
    message.contains("environment") ||
    message.contains("cwd") ||
    message.contains("program") ||
    message.contains("risk tier") ||
    message.contains("stdin")
  @contracts.RpcError::new(
    if invalid {
      @contracts.ERR_INVALID_PARAMS
    } else {
      @contracts.ERR_HOST
    },
    message,
  )
}

///|
fn require_string(
  params : Map[String, @json.Json],
  key : String,
) -> Result[String, @contracts.RpcError] {
  match @contracts.string_field(params, key) {
    Some(value) =>
      if value == "" {
        Err(invalid_params(key + " must not be empty"))
      } else {
        Ok(value)
      }
    None => Err(invalid_params("missing " + key))
  }
}

///|
fn optional_string(params : Map[String, @json.Json], key : String) -> String {
  match @contracts.string_field(params, key) {
    Some(value) => value
    None => ""
  }
}

///|
fn require_safe_id(
  params : Map[String, @json.Json],
  key : String,
) -> Result[String, @contracts.RpcError] {
  let value = match require_string(params, key) {
    Ok(text) => text
    Err(error) => return Err(error)
  }
  if !@transport.is_safe_id(value) {
    return Err(invalid_params(key + " is not a safe runtime id"))
  }
  Ok(value)
}

///|
fn require_argv(
  params : Map[String, @json.Json],
) -> Result[Array[String], @contracts.RpcError] {
  let values = match params.get("argv") {
    Some(@json.Json::Array(items)) => items
    _ => return Err(invalid_params("argv must be an array of strings"))
  }
  if values.is_empty() {
    return Err(invalid_params("argv must not be empty"))
  }
  if values.length() > 256 {
    return Err(invalid_params("argv has too many elements"))
  }
  let argv : Array[String] = []
  for item in values {
    let text = match @contracts.as_string(item) {
      Some(value) => value
      None => return Err(invalid_params("argv must contain only strings"))
    }
    if text.length() > 4_096 {
      return Err(invalid_params("argv element is too long"))
    }
    argv.push(text)
  }
  Ok(argv)
}

///|
fn string_array_param(
  params : Map[String, @json.Json],
  key : String,
) -> Result[Array[String], @contracts.RpcError] {
  match params.get(key) {
    Some(@json.Json::Array(items)) => {
      if items.length() > 64 {
        return Err(invalid_params(key + " has too many elements"))
      }
      let out : Array[String] = []
      for item in items {
        let text = match @contracts.as_string(item) {
          Some(value) => value
          None => return Err(invalid_params(key + " must contain only strings"))
        }
        out.push(text)
      }
      Ok(out)
    }
    Some(_) => Err(invalid_params(key + " must be an array of strings"))
    None => Ok([])
  }
}

///|
fn env_entries(
  params : Map[String, @json.Json],
  key : String,
) -> Result[Array[(String, String)], @contracts.RpcError] {
  match params.get(key) {
    Some(@json.Json::Object(entries)) => {
      if entries.length() > 64 {
        return Err(invalid_params(key + " has too many entries"))
      }
      let out : Array[(String, String)] = []
      for name, value in entries {
        if name == "" || name.length() > 128 {
          return Err(invalid_params("invalid environment variable name"))
        }
        let text = match @contracts.as_string(value) {
          Some(item) => item
          None => return Err(invalid_params(key + " values must be strings"))
        }
        if text.length() > 8_192 {
          return Err(invalid_params("environment value is too long"))
        }
        out.push((name, text))
      }
      Ok(out)
    }
    Some(_) => Err(invalid_params(key + " must be an object"))
    None => Ok([])
  }
}

///|
fn env_pairs(
  params : Map[String, @json.Json],
) -> Result[Array[@runtime.EnvPair], @contracts.RpcError] {
  let entries = match env_entries(params, "env") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let out : Array[@runtime.EnvPair] = []
  for pair in entries {
    out.push(@runtime.EnvPair::new(pair.0, pair.1))
  }
  Ok(out)
}

///|
fn int_param_or(
  params : Map[String, @json.Json],
  key : String,
  default : Int,
) -> Int {
  @contracts.int_field_or(params, key, default)
}

///|
fn int64_param_or(
  params : Map[String, @json.Json],
  key : String,
  default : Int64,
) -> Int64 {
  @contracts.int64_field_or(params, key, default)
}

///|
fn bool_param_or(
  params : Map[String, @json.Json],
  key : String,
  default : Bool,
) -> Bool {
  @contracts.bool_field_or(params, key, default)
}

///|
fn runtime_info_json(info : @runtime.RunInfo) -> @json.Json {
  info.to_json()
}

// ---------------------------------------------------------------------------
// Policy classification (A1.3b)
// ---------------------------------------------------------------------------

///|
/// The result of the local risk check for one request. `decision` is the same
/// `@policy.PolicyDecision` the primary derives; it is attached to results as
/// bounded metadata (never argv values).
struct PolicyCheckResult {
  decision : @policy.PolicyDecision
  approval_verified : Bool
  /// The cwd that will actually be used by the runtime core, already resolved
  /// against the executor's real work root and expressed rooted-relative.
  cwd_rooted : String
}

///|
fn policy_denied_error(
  decision : @policy.PolicyDecision,
  operation : String,
) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @transport.ERR_POLICY_DENIED,
    "operation denied by installed policy: " + decision.reason,
    data=@contracts.json_object([
      ("kind", @contracts.json_string("policy_denied")),
      ("operation", @contracts.json_string(operation)),
      ("risk", @contracts.json_string(decision.risk)),
      ("reason", @contracts.json_string(decision.reason)),
      ("digest", @contracts.json_string(decision.digest)),
      ("policy_version", @contracts.json_string(decision.policy_version)),
      ("policy_hash", @contracts.json_string(decision.policy_hash)),
    ]),
  )
}

///|
fn policy_unverifiable_error(
  decision : @policy.PolicyDecision,
  operation : String,
) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @transport.ERR_POLICY_STALE,
    "operation cannot be verified under the installed policy: " +
    decision.reason,
    data=@contracts.json_object([
      ("kind", @contracts.json_string("policy_unverifiable")),
      ("operation", @contracts.json_string(operation)),
      ("risk", @contracts.json_string(decision.risk)),
      ("reason", @contracts.json_string(decision.reason)),
      ("digest", @contracts.json_string(decision.digest)),
      ("policy_version", @contracts.json_string(decision.policy_version)),
      ("policy_hash", @contracts.json_string(decision.policy_hash)),
    ]),
  )
}

///|
fn approval_required_error(
  decision : @policy.PolicyDecision,
  operation : String,
  binding_run_id : String,
  snapshot_expires_at_ms : Int64,
) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @transport.ERR_APPROVAL_REQUIRED,
    "owner approval is required for this operation",
    data=@contracts.json_object([
      ("kind", @contracts.json_string("approval_binding")),
      ("operation", @contracts.json_string(operation)),
      ("run_id", @contracts.json_string(binding_run_id)),
      ("risk", @contracts.json_string(decision.risk)),
      ("reason", @contracts.json_string(decision.reason)),
      ("digest", @contracts.json_string(decision.digest)),
      ("policy_version", @contracts.json_string(decision.policy_version)),
      ("policy_hash", @contracts.json_string(decision.policy_hash)),
      ("snapshot_expires_at_ms", @contracts.json_int64(snapshot_expires_at_ms)),
    ]),
  )
}

///|
fn grant_rejected_error(error : @policy.GrantError) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @transport.ERR_APPROVAL_INVALID,
    error.message(),
    data=@contracts.json_object([
      ("kind", @contracts.json_string("grant_rejected")),
      ("reason", @contracts.json_string(error.label())),
    ]),
  )
}

///|
fn malformed_grant_error() -> @contracts.RpcError {
  grant_rejected_error(@policy.GrantError::MalformedGrant)
}

///|
/// Bind a Decision/grant to the operation it authorizes. `exec.start` uses
/// its run id, `pty.open` its session id, and one-shot mutations their
/// idempotent `client_request_id`. Without a binding id the request cannot be
/// approved safely, so it is refused as invalid input rather than guessing.
fn approval_binding_id(
  method : String,
  params : Map[String, @json.Json],
  client_request_id : String,
) -> Result[String, @contracts.RpcError] {
  if method == @contracts.METHOD_RUNTIME_EXEC_START ||
    method == @contracts.METHOD_RUNTIME_PROCESS_START {
    return require_safe_id(params, "run_id")
  }
  if method == @contracts.METHOD_RUNTIME_PTY_OPEN {
    return require_safe_id(params, "session_id")
  }
  if client_request_id == "" {
    return Err(
      invalid_params(
        "client_request_id is required for an approval-bound mutation",
      ),
    )
  }
  Ok(client_request_id)
}

///|
fn env_names_for_policy(
  params : Map[String, @json.Json],
) -> Result[Array[String], @contracts.RpcError] {
  let names : Array[String] = []
  let env = match env_pairs(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for pair in env {
    names.push(pair.name)
  }
  let inherit = match string_array_param(params, "inherit_env") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for name in inherit {
    names.push(name)
  }
  Ok(names)
}

///|
/// Resolve a requested cwd against the executor's real work root. Empty or
/// relative cwd is rooted-relative; an absolute cwd must already sit inside
/// the real root. The returned absolute path is what the digest binds and what
/// the runtime core will actually resolve to; the rooted-relative form is what
/// `CommandSpec` accepts.
async fn policy_cwd(
  workspace_root : String,
  requested : String,
) -> Result[(String, String), @contracts.RpcError] {
  let root = @fs.realpath(workspace_root) catch {
    error =>
      return Err(
        invalid_params("cannot resolve the workspace root: " + error.to_string()),
      )
  }
  let trimmed = requested.trim().to_owned()
  let rooted = if trimmed == "" || trimmed == "." {
    ""
  } else if trimmed.has_prefix("/") {
    let normalized = match @policy.normalize_abs_path(trimmed) {
      Some(value) => value
      None => return Err(invalid_params("cwd is not an absolute path"))
    }
    if !@policy.path_within_root(root, normalized) {
      return Err(invalid_params("cwd escapes the workspace root"))
    }
    if normalized == root {
      ""
    } else if root == "/" {
      normalized[1:].to_owned()
    } else {
      normalized[root.length() + 1:].to_owned()
    }
  } else {
    match @runtime.normalize_rooted_path(trimmed) {
      Ok(value) => value
      Err(_) => return Err(invalid_params("cwd escapes the workspace root"))
    }
  }
  let lexical = if rooted == "" {
    root
  } else {
    root + "/" + rooted
  }
  let absolute = @fs.realpath(lexical) catch {
    _ => return Err(invalid_params("cwd does not exist"))
  }
  let inside = if root == "/" {
    absolute.has_prefix("/")
  } else {
    absolute == root || absolute.has_prefix(root + "/")
  }
  if !inside {
    return Err(invalid_params("cwd escapes the workspace root"))
  }
  let final_rooted = if absolute == root {
    ""
  } else if root == "/" {
    absolute[1:].to_owned()
  } else {
    absolute[root.length() + 1:].to_owned()
  }
  let kind = @fs.kind(absolute, follow_symlink=false) catch {
    _ => return Err(invalid_params("cwd is not a directory"))
  }
  match kind {
    @fs.FileKind::Directory => ()
    _ => return Err(invalid_params("cwd is not a directory"))
  }
  Ok((absolute, final_rooted))
}

///|
/// The exact execution request the node classifies. Every field the runtime
/// core will execute is bound: argv order, the resolved absolute cwd,
/// environment names *and values*, stdin, fs.write content and git worktree
/// flags. `None` means the method is a read-only method that cannot start new
/// work; control continuations are classified rather than skipped.
async fn execution_request_for(
  method : String,
  params : Map[String, @json.Json],
  workspace_root : String,
) -> Result[(@policy.ExecutionRequest, String)?, @contracts.RpcError] {
  let requested_cwd = optional_string(params, "cwd")
  let (cwd, cwd_rooted) = match
    policy_cwd(workspace_root, requested_cwd) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if method == @contracts.METHOD_RUNTIME_EXEC_START ||
    method == @contracts.METHOD_RUNTIME_PTY_OPEN ||
    method == @contracts.METHOD_RUNTIME_PROCESS_START {
    let argv = match require_argv(params) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let names = match env_names_for_policy(params) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let values = match env_entries(params, "env") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let stdin = optional_string(params, "stdin")
    let operation = if method == @contracts.METHOD_RUNTIME_EXEC_START ||
      method == @contracts.METHOD_RUNTIME_PROCESS_START {
      @policy.PolicyOperation::Exec
    } else {
      @policy.PolicyOperation::Pty
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(
          operation~,
          argv~,
          cwd~,
          workspace_root~,
          env_names=names,
          env_values=values,
          stdin~,
        ),
        cwd_rooted,
      )),
    )
  }
  if method == @contracts.METHOD_RUNTIME_FS_WRITE {
    let selector = match fs_root_selector(params) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let path = match require_string(params, "path") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let content = match @contracts.string_field(params, "content") {
      Some(value) => value
      None => return Err(invalid_params("missing content"))
    }
    // The selected root is part of the digest: writing the same relative path
    // under the workspace and under the environment root are different
    // operations. The workspace form keeps the A1.2 argv exactly.
    let argv = if selector == @contracts.RUNTIME_FS_ROOT_ENVIRONMENTS {
      ["environments:" + path]
    } else {
      [path]
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(
          operation=@policy.PolicyOperation::FsWrite,
          argv~,
          cwd~,
          workspace_root~,
          content~,
        ),
        cwd_rooted,
      )),
    )
  }
  if method == @contracts.METHOD_RUNTIME_FS_MKDIR ||
    method == @contracts.METHOD_RUNTIME_FS_REMOVE {
    let selector = match fs_root_selector(params) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let path = match require_string(params, "path") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let recursive = bool_param_or(params, "recursive", false)
    let target = if selector == @contracts.RUNTIME_FS_ROOT_ENVIRONMENTS {
      "environments:" + path
    } else {
      path
    }
    let argv = if method == @contracts.METHOD_RUNTIME_FS_MKDIR {
      if recursive {
        ["mkdir", target, "recursive"]
      } else {
        ["mkdir", target]
      }
    } else if recursive {
      ["remove", target, "recursive"]
    } else {
      ["remove", target]
    }
    let operation = if method == @contracts.METHOD_RUNTIME_FS_MKDIR {
      @policy.PolicyOperation::FsWrite
    } else {
      @policy.PolicyOperation::FsDelete
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(operation~, argv~, cwd~, workspace_root~),
        cwd_rooted,
      )),
    )
  }
  if method == @contracts.METHOD_RUNTIME_GIT_BRANCH_CREATE {
    let name = match require_string(params, "name") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let start = optional_string(params, "start")
    let argv = if start == "" {
      ["branch.create", name]
    } else {
      ["branch.create", name, start]
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(
          operation=@policy.PolicyOperation::GitWrite,
          argv~,
          cwd~,
          workspace_root~,
        ),
        cwd_rooted,
      )),
    )
  }
  if method == @contracts.METHOD_RUNTIME_GIT_CHECKOUT {
    let branch = match require_string(params, "branch") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let argv = if bool_param_or(params, "create", false) {
      ["checkout", branch, "create"]
    } else {
      ["checkout", branch]
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(
          operation=@policy.PolicyOperation::GitWrite,
          argv~,
          cwd~,
          workspace_root~,
        ),
        cwd_rooted,
      )),
    )
  }
  if method == @contracts.METHOD_RUNTIME_GIT_WORKTREE_ADD {
    let path = match require_string(params, "path") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let branch = optional_string(params, "branch")
    let base = optional_string(params, "base")
    let force = bool_param_or(params, "force", false)
    let argv = ["worktree.add", path]
    if branch != "" {
      argv.push(branch)
    }
    if base != "" {
      argv.push(base)
    }
    if force {
      argv.push("force")
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(
          operation=@policy.PolicyOperation::GitWrite,
          argv~,
          cwd~,
          workspace_root~,
          git_force=force,
          git_expected_head=base,
        ),
        cwd_rooted,
      )),
    )
  }
  if method == @contracts.METHOD_RUNTIME_GIT_WORKTREE_REMOVE {
    let path = match require_string(params, "path") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let force = bool_param_or(params, "force", false)
    let expected_head = optional_string(params, "expected_head")
    let expected_branch = optional_string(params, "expected_branch")
    let argv = ["worktree.remove", path]
    if force {
      argv.push("force")
    }
    if expected_head != "" {
      argv.push(expected_head)
    }
    if expected_branch != "" {
      argv.push(expected_branch)
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(
          operation=@policy.PolicyOperation::GitWrite,
          argv~,
          cwd~,
          workspace_root~,
          git_force=force,
          git_expected_head=expected_head,
          git_expected_branch=expected_branch,
        ),
        cwd_rooted,
      )),
    )
  }
  if method == @contracts.METHOD_RUNTIME_PROCESS_STDIN {
    let run_id = match require_safe_id(params, "run_id") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let data = match @contracts.string_field(params, "data") {
      Some(value) => value
      None => return Err(invalid_params("missing data"))
    }
    return Ok(
      Some((
        @policy.ExecutionRequest::new(
          operation=@policy.PolicyOperation::Control,
          argv=["process.stdin", run_id],
          cwd~,
          workspace_root~,
          stdin=data,
        ),
        cwd_rooted,
      )),
    )
  }
  // Control continuations mutate a run/session that already passed the
  // classifier. They are evaluated against the installed snapshot like any
  // other mutation and audited as such; they are not silently skipped.
  let control_id = if method == @contracts.METHOD_RUNTIME_EXEC_CANCEL ||
    method == @contracts.METHOD_RUNTIME_PROCESS_CANCEL {
    require_safe_id(params, "run_id")
  } else if method == @contracts.METHOD_RUNTIME_PTY_INPUT ||
    method == @contracts.METHOD_RUNTIME_PTY_RESIZE ||
    method == @contracts.METHOD_RUNTIME_PTY_CLOSE {
    require_safe_id(params, "session_id")
  } else {
    return Ok(None)
  }
  let id = match control_id {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let label = if method == @contracts.METHOD_RUNTIME_EXEC_CANCEL {
    "exec.cancel"
  } else if method == @contracts.METHOD_RUNTIME_PROCESS_CANCEL {
    "process.cancel"
  } else if method == @contracts.METHOD_RUNTIME_PTY_INPUT {
    "pty.input"
  } else if method == @contracts.METHOD_RUNTIME_PTY_RESIZE {
    "pty.resize"
  } else {
    "pty.close"
  }
  Ok(
    Some((
      @policy.ExecutionRequest::new(
        operation=@policy.PolicyOperation::Control,
        argv=[label, id],
        cwd~,
        workspace_root~,
      ),
      cwd_rooted,
    )),
  )
}

///|
fn attach_policy_metadata(
  result : @json.Json,
  check : PolicyCheckResult,
) -> @json.Json {
  let object = match @contracts.as_object(result) {
    Some(value) => value
    None => return result
  }
  object.set("policy", check.decision.to_json())
  if check.approval_verified {
    object.set("approval_verified", @contracts.json_bool(true))
  } else {
    // A cached or durable replay may carry a stale approval flag from an
    // earlier decision. Re-stamping always reflects the current check.
    object.remove("approval_verified")
  }
  @json.Json::object(object)
}

///|
/// The digest recorded in a result's policy metadata, or "" when the result
/// carries none.
fn recorded_result_digest(result : @json.Json) -> String {
  match @contracts.as_object(result) {
    Some(object) =>
      match object.get("policy") {
        Some(@json.Json::Object(policy)) =>
          @contracts.string_field_or(policy, "digest", "")
        _ => ""
      }
    None => ""
  }
}

///|
/// Re-stamp a cached or durably recorded result with the policy metadata of
/// the check that just ran. The policy gate runs before every lookup, so a
/// replay of the same request can never return a result stamped under a
/// rotated snapshot. A replay carrying a different payload keeps the recorded
/// result byte-for-byte: its digest names the request that actually executed,
/// not the one that was refused by the idempotency check.
fn restamp_policy_metadata(
  result : @json.Json,
  check : PolicyCheckResult?,
) -> @json.Json {
  match check {
    Some(metadata) => {
      let recorded = recorded_result_digest(result)
      if recorded == "" || recorded == metadata.decision.digest {
        attach_policy_metadata(result, metadata)
      } else {
        result
      }
    }
    None => result
  }
}

///|
/// Classify one request under the installed snapshot and enforce the result.
///
/// - `snapshot` mode: `evaluate` runs the same policy the primary runs.
///   `Allow` proceeds, `Deny` returns 1011, `Unverifiable` returns 1006, and
///   `ApprovalRequired` needs a grant bound to this run and digest; the grant
///   nonce is consumed exactly once before execution.
/// - `override`/`fail_closed`: no typed snapshot, so the workspace-root gate
///   (already enforced before this call) is the whole check. Reads are
///   audited; mutations under override are audited as operator-overridden.
async fn NodeHost::classify_policy(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[PolicyCheckResult?, @contracts.RpcError] {
  let method = request.rpc_method
  let snapshot = match self.policy.verified_snapshot() {
    Some(value) => value
    None => {
      let override = @contracts.runtime_method_mutates(method)
      let outcome = if override {
        "operator_override"
      } else {
        "read_unverified"
      }
      let detail = "method=" +
        method +
        " mode=" +
        self.policy.mode() +
        " outcome=" +
        outcome
      node_audit(self, "policy.decision", "ok", detail)
      return Ok(None)
    }
  }
  let (execution, cwd_rooted) = match
    execution_request_for(method, request.params, self.workspace_root) {
    Ok(Some(value)) => value
    Ok(None) => {
      node_audit(
        self,
        "policy.decision",
        "read_only",
        "method=" +
        method +
        " policy_version=" +
        snapshot.version +
        " outcome=control",
      )
      return Ok(None)
    }
    Err(error) => return Err(error)
  }
  let context = @policy.PolicyContext::with_snapshot(
    snapshot,
    now_ms=@async.now(),
    primary_reachable=true,
  )
  let decision = @policy.evaluate(context, execution)
  let operation = execution.operation.label()
  let detail = "method=" +
    method +
    " operation=" +
    operation +
    " risk=" +
    decision.risk +
    " kind=" +
    decision.kind.label() +
    " digest=" +
    decision.digest +
    " policy_version=" +
    decision.policy_version
  match decision.kind {
    @policy.DecisionKind::Allow => {
      node_audit(self, "policy.decision", decision.kind.label(), detail)
      Ok(Some({ decision, approval_verified: false, cwd_rooted }))
    }
    @policy.DecisionKind::Deny => {
      node_audit(self, "policy.decision", decision.kind.label(), detail)
      Err(policy_denied_error(decision, operation))
    }
    @policy.DecisionKind::Unverifiable => {
      node_audit(self, "policy.decision", decision.kind.label(), detail)
      Err(policy_unverifiable_error(decision, operation))
    }
    @policy.DecisionKind::ApprovalRequired => {
      let binding_run_id = match
        approval_binding_id(method, request.params, request.client_request_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let grant_text = match
        @contracts.string_field(request.params, "approval") {
        Some(value) => value
        None => ""
      }
      if grant_text == "" {
        node_audit(
          self,
          "policy.decision",
          decision.kind.label(),
          detail + " run_id=" + binding_run_id + " outcome=waiting_for_owner",
        )
        return Err(
          approval_required_error(
            decision,
            operation,
            binding_run_id,
            snapshot.expires_at_ms,
          ),
        )
      }
      let grant = match @policy.ApprovalGrant::decode(grant_text) {
        Ok(value) => value
        Err(_) => {
          node_audit(
            self,
            "policy.approval_rejected",
            "rejected",
            detail + " reason=malformed_grant",
          )
          return Err(malformed_grant_error())
        }
      }
      match
        @policy.verify_and_consume_for_request(
          grant,
          binding_run_id,
          execution,
          Some(snapshot),
          @async.now(),
          self.nonces,
        ) {
        Ok(_) => {
          match self.persist_consumed_nonces() {
            Ok(_) => ()
            Err(_) => {
              node_audit(
                self,
                "policy.approval_rejected",
                "rejected",
                detail +
                " run_id=" +
                binding_run_id +
                " reason=nonce_store_unavailable",
              )
              return Err(
                @contracts.RpcError::new(
                  @contracts.ERR_HOST,
                  "cannot persist the consumed approval nonce",
                ),
              )
            }
          }
          node_audit(
            self,
            "policy.approval_used",
            decision.kind.label(),
            detail + " run_id=" + binding_run_id + " outcome=consumed",
          )
          Ok(Some({ decision, approval_verified: true, cwd_rooted }))
        }
        Err(error) => {
          node_audit(
            self,
            "policy.approval_rejected",
            "rejected",
            detail +
            " run_id=" +
            binding_run_id +
            " reason=" +
            error.label(),
          )
          Err(grant_rejected_error(error))
        }
      }
    }
  }
}

///|
/// Combined workspace-root and policy gate for one request. Keeping both checks
/// in one synchronous place lets `dispatch` stay a single decision point: the
/// cache is consulted only after the gate passed, so a replayed mutating
/// request can never bypass a rotated or unverifiable policy.
async fn NodeHost::policy_gate(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[PolicyCheckResult?, @contracts.RpcError] {
  match self.policy.authorize(request.rpc_method, self.workspace_root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  self.classify_policy(request)
}

///|
pub async fn NodeHost::dispatch(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
) -> Result[@json.Json, @contracts.RpcError] {
  let method = request.rpc_method
  // The policy check runs before the idempotency cache so a revoked, stale or
  // rotated policy cannot be bypassed by replaying a cached mutating request.
  let check = match self.policy_gate(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let crid = request.client_request_id
  match self.cache.lookup(method, crid) {
    Some(value) => return Ok(restamp_policy_metadata(value, check))
    None => ()
  }
  // exec.start has its own durable run record and idempotent start path; every
  // other mutation gets a durable tombstone before it executes, so a lost
  // response followed by a node restart cannot execute it twice.
  let durable_keyed = @contracts.runtime_method_mutates(method) &&
    method != @contracts.METHOD_RUNTIME_EXEC_START && crid != ""
  if durable_keyed {
    match self.durable.lookup(method, crid) {
      DurableDone(value) => {
        let restamped = restamp_policy_metadata(value, check)
        self.cache.remember(method, crid, restamped)
        return Ok(restamped)
      }
      DurablePending => {
        node_audit(
          self,
          "policy.idempotency",
          "rejected",
          "method=" + method + " reason=in_flight_or_result_lost",
        )
        return Err(
          @contracts.RpcError::new(
            @contracts.ERR_HOST,
            "this client_request_id was already accepted and its result is not available; retry with a new client_request_id",
          ),
        )
      }
      DurableMissing => ()
    }
    match self.durable.begin(method, crid) {
      Ok(_) => ()
      Err(_) =>
        return Err(
          @contracts.RpcError::new(
            @contracts.ERR_HOST,
            "cannot persist the mutation idempotency record",
          ),
        )
    }
  }
  let result = self.dispatch_inner(request, group, check)
  let value = match result {
    Ok(value) => value
    Err(error) => {
      if durable_keyed {
        // Nothing was reported as executed; drop the tombstone so a corrected
        // retry with the same client_request_id can run.
        self.durable.abandon(method, crid)
      }
      return Err(error)
    }
  }
  let stamped = restamp_policy_metadata(value, check)
  self.cache.remember(method, crid, stamped)
  if durable_keyed {
    match self.durable.finish(method, crid, stamped) {
      Ok(_) => ()
      Err(_) => {
        // The tombstone stays `pending` on disk: a restart refuses a second
        // execution. Live retries still hit the in-memory cache.
        node_audit(
          self,
          "policy.idempotency",
          "degraded",
          "method=" + method + " reason=result_not_persisted",
        )
      }
    }
  }
  Ok(stamped)
}

///|
async fn NodeHost::dispatch_inner(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
  check : PolicyCheckResult?,
) -> Result[@json.Json, @contracts.RpcError] {
  let method = request.rpc_method
  if method == @contracts.METHOD_RUNTIME_EXEC_START {
    return self.exec_start(request, group, check)
  }
  if method == @contracts.METHOD_RUNTIME_EXEC_STATUS {
    return self.exec_status(request)
  }
  if method == @contracts.METHOD_RUNTIME_EXEC_READ {
    return self.exec_read(request)
  }
  if method == @contracts.METHOD_RUNTIME_EXEC_CANCEL {
    return self.exec_cancel(request)
  }
  if method == @contracts.METHOD_RUNTIME_PROCESS_START {
    return self.process_start(request, group, check)
  }
  if method == @contracts.METHOD_RUNTIME_PROCESS_STDIN {
    return self.process_stdin(request)
  }
  if method == @contracts.METHOD_RUNTIME_PROCESS_STDOUT {
    return self.process_read(request, "stdout")
  }
  if method == @contracts.METHOD_RUNTIME_PROCESS_STDERR {
    return self.process_read(request, "stderr")
  }
  if method == @contracts.METHOD_RUNTIME_PROCESS_EXIT {
    return self.process_exit(request)
  }
  if method == @contracts.METHOD_RUNTIME_PROCESS_CANCEL {
    return self.process_cancel(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_READ {
    return self.fs_read(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_WRITE {
    return self.fs_write(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_MKDIR {
    return self.fs_mkdir(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_REMOVE {
    return self.fs_remove(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_LIST {
    return self.fs_list(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_STAT {
    return self.fs_stat(request)
  }
  if method == @contracts.METHOD_RUNTIME_PTY_OPEN {
    return self.pty_open(request, group, check)
  }
  if method == @contracts.METHOD_RUNTIME_PTY_INPUT {
    return self.pty_input(request)
  }
  if method == @contracts.METHOD_RUNTIME_PTY_RESIZE {
    return self.pty_resize(request)
  }
  if method == @contracts.METHOD_RUNTIME_PTY_CLOSE {
    return self.pty_close(request)
  }
  if method == @contracts.METHOD_RUNTIME_PTY_STATUS {
    return self.pty_status(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_STATUS {
    return self.git_status(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_DIFF {
    return self.git_diff(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_LOG {
    return self.git_log(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_SHOW {
    return self.git_show(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_BRANCHES {
    return self.git_branches(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_BRANCH_CREATE {
    return self.git_branch_create(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_CHECKOUT {
    return self.git_checkout(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_WORKTREES {
    return self.git_worktrees(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_WORKTREE_ADD {
    return self.git_worktree_add(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_WORKTREE_REMOVE {
    return self.git_worktree_remove(request)
  }
  if method == @contracts.METHOD_RUNTIME_GIT_READ_OUTPUT {
    return self.git_read_output(request)
  }
  Err(
    @contracts.RpcError::new(
      @contracts.ERR_METHOD_NOT_FOUND,
      "method not found: " + method,
    ),
  )
}

///|
async fn NodeHost::exec_start(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
  check : PolicyCheckResult?,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let run_id = match require_safe_id(params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let client_request_id = if request.client_request_id != "" {
    request.client_request_id
  } else {
    "run-" + run_id
  }
  let argv = match require_argv(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let env = match env_pairs(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let inherit_env = match string_array_param(params, "inherit_env") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stdin = match @contracts.string_field(params, "stdin") {
    Some(value) => Some(value)
    None => None
  }
  // The cwd reaches the executor rooted-relative, exactly as it was resolved
  // for the digest. A snapshot-checked request reuses that resolution; the
  // operator-override path resolves it here so an absolute cwd cannot slip
  // past the rooted executor.
  let cwd = match check {
    Some(value) => value.cwd_rooted
    None =>
      match policy_cwd(self.workspace_root, optional_string(params, "cwd")) {
        Ok((_absolute, rooted)) => rooted
        Err(error) => return Err(error)
      }
  }
  let spec = @runtime.CommandSpec::new(
    argv~,
    cwd~,
    env~,
    inherit_env~,
    timeout_ms=int_param_or(params, "timeout_ms", 0),
    risk=optional_string(params, "risk"),
    stdin~,
    max_output_bytes=int_param_or(params, "max_output_bytes", 0),
  )
  let outcome = match
    self.executor.start(
      group,
      client_request_id~,
      run_id~,
      spec~,
    ) {
    Ok(value) => value
    Err(message) => return Err(start_failure(message))
  }
  let (info, existing) = match outcome {
    @runtime.StartOutcome::Started(value) => (value, false)
    @runtime.StartOutcome::Existing(value) => (value, true)
  }
  Ok(
    @contracts.json_object([
      ("run", runtime_info_json(info)),
      ("existing", @contracts.json_bool(existing)),
    ]),
  )
}

///|
async fn NodeHost::exec_status(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let run_id = optional_string(params, "run_id")
  if run_id != "" {
    if !@transport.is_safe_id(run_id) {
      return Err(invalid_params("invalid run_id"))
    }
    let run = match self.executor.status(run_id) {
      Some(value) => value.to_json()
      None => @contracts.json_null()
    }
    return Ok(@contracts.json_object([("run", run)]))
  }
  let runs : Array[@json.Json] = []
  for info in self.executor.runs() {
    if runs.length() >= MAX_RUNS_PER_STATUS {
      break
    }
    runs.push(info.to_json())
  }
  Ok(@contracts.json_object([("runs", @contracts.json_array(runs))]))
}

///|
async fn NodeHost::exec_cancel(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let run_id = match require_safe_id(request.params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let info = match self.executor.cancel(run_id) {
    Ok(value) => value
    Err(message) =>
      return Err(
        @contracts.RpcError::new(@contracts.ERR_HOST, message),
      )
  }
  Ok(@contracts.json_object([("run", runtime_info_json(info))]))
}

///|
fn process_info_json(info : @runtime.ProcessInfo) -> @json.Json {
  info.to_json()
}

///|
/// Start a streaming process (A1.4). The policy gate has already classified
/// the exact argv/cwd/env payload as `Exec`, and a high-risk start carries the
/// same run_id-bound approval as `exec.start`. The node never sees a shell
/// string and never inherits a credential the primary did not name.
async fn NodeHost::process_start(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
  check : PolicyCheckResult?,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let run_id = match require_safe_id(params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let client_request_id = if request.client_request_id != "" {
    request.client_request_id
  } else {
    "process-" + run_id
  }
  let argv = match require_argv(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let env = match env_pairs(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let inherit_env = match string_array_param(params, "inherit_env") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let cwd = match check {
    Some(value) => value.cwd_rooted
    None =>
      match policy_cwd(self.workspace_root, optional_string(params, "cwd")) {
        Ok((_absolute, rooted)) => rooted
        Err(error) => return Err(error)
      }
  }
  let spec = @runtime.ProcessSpec::new(
    argv~,
    cwd~,
    env~,
    inherit_env~,
    timeout_ms=int64_param_or(params, "timeout_ms", 0L),
    risk=optional_string(params, "risk"),
    max_output_bytes=int64_param_or(params, "max_output_bytes", 0L),
  )
  let outcome = match
    self.executor.process().start(
      group,
      client_request_id~,
      run_id~,
      spec~,
    ) {
    Ok(value) => value
    Err(message) => return Err(start_failure(message))
  }
  let (info, existing) = outcome
  Ok(
    @contracts.json_object([
      ("process", process_info_json(info)),
      ("existing", @contracts.json_bool(existing)),
    ]),
  )
}

///|
async fn NodeHost::process_stdin(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let run_id = match require_safe_id(params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let data = match @contracts.string_field(params, "data") {
    Some(value) => value
    None => return Err(invalid_params("missing data"))
  }
  if data.length() > 48_000 {
    return Err(invalid_params("data is larger than the stdin bound"))
  }
  let bytes = @base64.decode(data) catch {
    _ => return Err(invalid_params("data is not valid base64"))
  }
  if bytes.length() > @runtime.PROCESS_MAX_STDIN_BYTES {
    return Err(invalid_params("data is larger than the stdin bound"))
  }
  let info = match self.executor.process().write_stdin(run_id, bytes) {
    Ok(value) => value
    Err(message) => return Err(@contracts.RpcError::new(@contracts.ERR_HOST, message))
  }
  Ok(
    @contracts.json_object([
      ("process", process_info_json(info)),
      ("accepted", @contracts.json_bool(true)),
      ("bytes", @contracts.json_int(bytes.length())),
    ]),
  )
}

///|
async fn NodeHost::process_read(
  self : NodeHost,
  request : @transport.HandlerRequest,
  stream : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let run_id = match require_safe_id(params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let offset = int64_param_or(params, "offset", 0L)
  if offset < 0L {
    return Err(invalid_params("offset must not be negative"))
  }
  let max_bytes = int_param_or(params, "max_bytes", 16_384).max(1).min(
    @runtime.PROCESS_MAX_READ_BYTES,
  )
  let chunk = match
    self.executor.process().read_stream(run_id, stream, offset, max_bytes) {
    Ok(value) => value
    Err(message) => return Err(@contracts.RpcError::new(@contracts.ERR_HOST, message))
  }
  Ok(@contracts.json_object([("chunk", chunk.to_json())]))
}

///|
async fn NodeHost::process_exit(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let run_id = match require_safe_id(request.params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let info = match self.executor.process().exit(run_id) {
    Ok(value) => value
    Err(message) => return Err(@contracts.RpcError::new(@contracts.ERR_HOST, message))
  }
  Ok(@contracts.json_object([("process", process_info_json(info))]))
}

///|
async fn NodeHost::process_cancel(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let run_id = match require_safe_id(request.params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let info = match self.executor.process().cancel(run_id) {
    Ok(value) => value
    Err(message) => return Err(@contracts.RpcError::new(@contracts.ERR_HOST, message))
  }
  Ok(@contracts.json_object([("process", process_info_json(info))]))
}

///|
/// Read a bounded slice of one exec stream log. The run id is validated before
/// it becomes a path component, the resolved file must be a regular file under
/// the node's real logs root, and the slice is bounded by both the transport
/// result limit and the file size. This is a read method: no approval is
/// required, and it never returns a run's status as success.
async fn NodeHost::exec_read(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let run_id = match require_safe_id(params, "run_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stream = optional_string(params, "stream")
  let stream = if stream == "" { "stdout" } else { stream }
  if stream != "stdout" && stream != "stderr" {
    return Err(invalid_params("stream must be stdout or stderr"))
  }
  let offset = int64_param_or(params, "offset", 0L)
  if offset < 0L {
    return Err(invalid_params("offset must not be negative"))
  }
  let max_bytes = int_param_or(params, "max_bytes", MAX_EXEC_OUTPUT_CHARS)
    .max(1)
    .min(MAX_EXEC_OUTPUT_CHARS)
  let logs_root = @fs.realpath(self.executor.state_root() + "/logs") catch {
    _ =>
      return Err(
        @contracts.RpcError::new(
          @contracts.ERR_INVALID_PARAMS,
          "no exec log directory exists on this node",
        ),
      )
  }
  let path = logs_root + "/" + run_id + "/" + stream + ".log"
  let stat = match @transport.lstat_path(path) {
    None =>
      return Err(
        @contracts.RpcError::new(
          @contracts.ERR_INVALID_PARAMS,
          "no such exec log",
        ),
      )
    Some(value) => value
  }
  match stat.kind {
    @transport.PathKind::Regular => ()
    _ => return Err(fs_failure("exec log is not a regular file"))
  }
  let real = @fs.realpath(path) catch {
    error => return Err(fs_failure("cannot resolve exec log: " + error.to_string()))
  }
  if !real_within_root(logs_root, real) {
    return Err(
      @contracts.RpcError::new(
        @transport.ERR_PATH_DENIED,
        "exec log escapes the node log root",
      ),
    )
  }
  let size = stat.size
  let mut read_bytes = 0L
  let data = if offset >= size {
    ""
  } else {
    let available = size - offset
    let requested = if available > max_bytes.to_int64() {
      max_bytes
    } else {
      available.to_int()
    }
    let file = @fs.open(
      real,
      mode=@fs.Mode::ReadOnly,
      create_mode=@fs.CreateMode::OpenExisting,
    ) catch {
      error => return Err(fs_failure("cannot open exec log: " + error.to_string()))
    }
    defer file.close()
    let buffer : FixedArray[Byte] = FixedArray::make(requested, b'\x00')
    let mut got = 0
    while got < requested {
      let count = file.read_at(
        buffer,
        position=offset + got.to_int64(),
        offset=got,
        len=requested - got,
      )
      if count <= 0 {
        break
      }
      got = got + count
    }
    read_bytes = got.to_int64()
    @utf8.decode_lossy(Bytes::from_fixedarray(buffer, len=got)[:], ignore_bom=false)
  }
  Ok(
    @contracts.json_object([
      ("run_id", @contracts.json_string(run_id)),
      ("stream", @contracts.json_string(stream)),
      ("offset", @contracts.json_int64(offset)),
      ("data", @contracts.json_string(data)),
      ("bytes", @contracts.json_int64(read_bytes)),
      ("eof", @contracts.json_bool(offset + read_bytes >= size)),
      ("log_bytes", @contracts.json_int64(size)),
    ]),
  )
}

///|
async fn NodeHost::fs_read(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let path = match require_string(params, "path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let requested = int_param_or(params, "max_bytes", MAX_FS_READ_CHARS)
  let limit = requested.max(1).min(MAX_FS_READ_CHARS)
  let stat = match self.workspace.stat(path) {
    Ok(value) => value
    Err(message) => return Err(fs_failure(message))
  }
  if stat.size > MAX_FS_READ_FILE_BYTES {
    return Err(
      result_too_large(
        "file is too large to read over the transport: " +
        stat.size.to_string() +
        " bytes",
      ),
    )
  }
  let text = match self.workspace.read_text(path) {
    Ok(value) => value
    Err(message) => return Err(fs_failure(message))
  }
  let truncated = text.length() > limit
  let data = if truncated {
    text[:limit].to_string()
  } else {
    text
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(path)),
      ("data", @contracts.json_string(data)),
      ("truncated", @contracts.json_bool(truncated)),
      ("bytes", @contracts.json_int64(stat.size)),
    ]),
  )
}

///|
async fn NodeHost::fs_write(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let selector = match fs_root_selector(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let path = match require_string(params, "path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let content = match @contracts.string_field(params, "content") {
    Some(value) => value
    None => return Err(invalid_params("missing content"))
  }
  if content.length() > MAX_FS_WRITE_CHARS {
    return Err(
      result_too_large(
        "content exceeds " + MAX_FS_WRITE_CHARS.to_string() + " characters",
      ),
    )
  }
  let root = match self.selected_root(selector) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match root.write_text(path, content) {
    Ok(_) => ()
    Err(message) => return Err(fs_failure(message))
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(path)),
      ("bytes", @contracts.json_int(content.length())),
      ("written", @contracts.json_bool(true)),
      ("root", @contracts.json_string(selector)),
    ]),
  )
}

///|
async fn NodeHost::fs_mkdir(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let selector = match fs_root_selector(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let path = match require_string(params, "path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let recursive = bool_param_or(params, "recursive", false)
  let root = match self.selected_root(selector) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match rooted_mkdir(root, path, recursive) {
    Ok(_) => ()
    Err(message) => return Err(fs_failure(message))
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(path)),
      ("created", @contracts.json_bool(true)),
      ("root", @contracts.json_string(selector)),
    ]),
  )
}

///|
async fn NodeHost::fs_remove(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let selector = match fs_root_selector(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let path = match require_string(params, "path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let recursive = bool_param_or(params, "recursive", false)
  let root = match self.selected_root(selector) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match rooted_remove(root, path, recursive) {
    Ok(_) => ()
    Err(message) => return Err(fs_failure(message))
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(path)),
      ("removed", @contracts.json_bool(true)),
      ("root", @contracts.json_string(selector)),
    ]),
  )
}

///|
async fn NodeHost::fs_list(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let path = optional_string(request.params, "path")
  let entries = match self.workspace.list(path) {
    Ok(value) => value
    Err(message) =>
      return Err(
        @contracts.RpcError::new(@contracts.ERR_INVALID_PARAMS, message),
      )
  }
  let items : Array[@json.Json] = []
  let mut truncated = false
  for entry in entries {
    if items.length() >= MAX_LIST_ENTRIES {
      truncated = true
      break
    }
    items.push(
      @contracts.json_object([
        ("name", @contracts.json_string(entry.name)),
        ("path", @contracts.json_string(entry.path)),
        ("kind", @contracts.json_string(entry.kind)),
        ("is_dir", @contracts.json_bool(entry.is_dir)),
        ("size", @contracts.json_int64(entry.size)),
      ]),
    )
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(path)),
      ("entries", @contracts.json_array(items)),
      ("truncated", @contracts.json_bool(truncated)),
    ]),
  )
}

///|
async fn NodeHost::fs_stat(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let selector = match fs_root_selector(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let path = optional_string(params, "path")
  let root = match self.selected_root(selector) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stat = match root.stat(path) {
    Ok(value) => value
    Err(message) =>
      return Err(
        @contracts.RpcError::new(@contracts.ERR_INVALID_PARAMS, message),
      )
  }
  let absolute = if stat.path == "" {
    root.root()
  } else {
    root.root() + "/" + stat.path
  }
  let mode = match @transport.stat_path(absolute) {
    Some(value) => value.mode & 0o777
    None => 0
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(stat.path)),
      ("kind", @contracts.json_string(stat.kind)),
      ("size", @contracts.json_int64(stat.size)),
      ("mode", @contracts.json_int(mode)),
      ("root", @contracts.json_string(selector)),
    ]),
  )
}

///|
async fn NodeHost::pty_open(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
  check : PolicyCheckResult?,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let session_id = match require_safe_id(params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let requested_root = optional_string(params, "workspace_root")
  if requested_root != "" && requested_root != self.workspace_root {
    return Err(
      @contracts.RpcError::new(
        @transport.ERR_PATH_DENIED,
        "PTY workspace_root must be the node's registered workspace",
      ),
    )
  }
  let argv = match require_argv(params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let env = match env_entries(params, "env") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let rows = int_param_or(params, "rows", 24).max(1).min(1_000)
  let cols = int_param_or(params, "cols", 80).max(1).min(1_000)
  let client_request_id = if request.client_request_id != "" {
    request.client_request_id
  } else {
    "pty-" + session_id
  }
  let cwd = match check {
    Some(value) => value.cwd_rooted
    None =>
      match policy_cwd(self.workspace_root, optional_string(params, "cwd")) {
        Ok((_absolute, rooted)) => rooted
        Err(error) => return Err(error)
      }
  }
  let outcome = match
    self.executor.pty_open(
      group,
      session_id~,
      client_request_id~,
      argv~,
      cwd~,
      env~,
      rows~,
      cols~,
      workspace_root=self.workspace_root,
    ) {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  let (info, existing) = match outcome {
    @runtime.PtyOpenOutcome::Opened(value) => (value, false)
    @runtime.PtyOpenOutcome::Existing(value) => (value, true)
  }
  Ok(
    @contracts.json_object([
      ("session", info.to_json()),
      ("existing", @contracts.json_bool(existing)),
    ]),
  )
}

///|
async fn NodeHost::pty_input(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let session_id = match require_safe_id(params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if request.client_request_id == "" {
    return Err(invalid_params("missing client_request_id"))
  }
  let data = match @contracts.string_field(params, "data") {
    Some(value) => value
    None => return Err(invalid_params("missing data"))
  }
  if data.length() > MAX_PTY_INPUT_CHARS {
    return Err(
      result_too_large(
        "PTY input exceeds " + MAX_PTY_INPUT_CHARS.to_string() + " characters",
      ),
    )
  }
  match self.executor.pty_input(session_id, data) {
    Ok(_) => ()
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(
    @contracts.json_object([
      ("session_id", @contracts.json_string(session_id)),
      ("accepted", @contracts.json_bool(true)),
    ]),
  )
}

///|
async fn NodeHost::pty_resize(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let session_id = match require_safe_id(params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if request.client_request_id == "" {
    return Err(invalid_params("missing client_request_id"))
  }
  let rows = int_param_or(params, "rows", 0)
  let cols = int_param_or(params, "cols", 0)
  if rows <= 0 || cols <= 0 || rows > 1_000 || cols > 1_000 {
    return Err(invalid_params("rows and cols must be between 1 and 1000"))
  }
  match self.executor.pty_resize(session_id, rows~, cols~) {
    Ok(_) => ()
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(
    @contracts.json_object([
      ("session_id", @contracts.json_string(session_id)),
      ("rows", @contracts.json_int(rows)),
      ("cols", @contracts.json_int(cols)),
    ]),
  )
}

///|
async fn NodeHost::pty_close(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let session_id = match require_safe_id(request.params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let info = match self.executor.pty_close(session_id) {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(@contracts.json_object([("session", info.to_json())]))
}

///|
async fn NodeHost::pty_status(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let session_id = match require_safe_id(request.params, "session_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let info = match self.executor.pty_status(session_id) {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(@contracts.json_object([("session", info.to_json())]))
}

///|
async fn NodeHost::open_git(self : NodeHost) -> Result[Unit, @contracts.RpcError] {
  match self.executor.open_git(workspace_root=self.workspace_root) {
    Ok(_) => Ok(())
    Err(error) => Err(runtime_failure(error))
  }
}

///|
async fn NodeHost::git_status(
  self : NodeHost,
  _request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match self.executor.git_status() {
    Ok(outcome) => Ok(outcome.to_json())
    Err(error) => Err(runtime_failure(error))
  }
}

///|
async fn NodeHost::git_diff(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outcome = match
    self.executor.git_diff(
      path=optional_string(params, "path"),
      cached=bool_param_or(params, "cached", false),
      range=optional_string(params, "range"),
    ) {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(outcome.to_json())
}

///|
async fn NodeHost::git_log(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let rev = match @contracts.string_field(params, "rev") {
    Some(value) if value != "" => value
    _ => "HEAD"
  }
  match
    self.executor.git_log(
      rev~,
      max_count=int_param_or(params, "max_count", 0),
      path=optional_string(params, "path"),
    ) {
    Ok(outcome) => Ok(outcome.to_json())
    Err(error) => Err(runtime_failure(error))
  }
}

///|
async fn NodeHost::git_show(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let rev = match require_string(params, "rev") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    self.executor.git_show(rev~, path=optional_string(params, "path")) {
    Ok(outcome) => Ok(outcome.to_json())
    Err(error) => Err(runtime_failure(error))
  }
}

///|
fn git_branch_json(branch : @git_runtime.GitBranch) -> @json.Json {
  @contracts.json_object([
    ("name", @contracts.json_string(branch.name)),
    ("head", @contracts.json_string(branch.head)),
    ("current", @contracts.json_bool(branch.current)),
  ])
}

///|
fn git_worktree_json(info : @git_runtime.WorktreeInfo) -> @json.Json {
  @contracts.json_object([
    ("path", @contracts.json_string(info.path)),
    ("relative_path", @contracts.json_string(info.relative_path)),
    ("branch", @contracts.json_string(info.branch)),
    ("head", @contracts.json_string(info.head)),
    ("detached", @contracts.json_bool(info.detached)),
    ("main", @contracts.json_bool(info.main)),
    ("registered", @contracts.json_bool(info.registered)),
    ("request_id", @contracts.json_string(info.request_id)),
  ])
}

///|
async fn NodeHost::git_branches(
  self : NodeHost,
  _request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outcome = match self.executor.git_branches() {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  let branches : Array[@json.Json] = []
  for branch in outcome.branches {
    branches.push(git_branch_json(branch))
  }
  Ok(
    @contracts.json_object([
      ("result", outcome.result.to_json()),
      ("branches", @contracts.json_array(branches)),
    ]),
  )
}

///|
async fn NodeHost::git_branch_create(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let name = match require_string(params, "name") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    self.executor.git_create_branch(name~, start=optional_string(params, "start")) {
    Ok(outcome) => Ok(outcome.to_json())
    Err(error) => Err(runtime_failure(error))
  }
}

///|
async fn NodeHost::git_checkout(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let branch = match require_string(params, "branch") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match
    self.executor.git_checkout(
      branch~,
      create=bool_param_or(params, "create", false),
    ) {
    Ok(outcome) => Ok(outcome.to_json())
    Err(error) => Err(runtime_failure(error))
  }
}

///|
async fn NodeHost::git_worktrees(
  self : NodeHost,
  _request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outcome = match self.executor.git_worktrees() {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  let worktrees : Array[@json.Json] = []
  for info in outcome.worktrees {
    worktrees.push(git_worktree_json(info))
  }
  Ok(
    @contracts.json_object([
      ("result", outcome.result.to_json()),
      ("worktrees", @contracts.json_array(worktrees)),
    ]),
  )
}

///|
async fn NodeHost::git_worktree_add(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let path = match require_string(params, "path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outcome = match
    self.executor.git_worktree_add(
      path~,
      branch=optional_string(params, "branch"),
      base=optional_string(params, "base"),
      client_request_id=request.client_request_id,
      force=bool_param_or(params, "force", false),
    ) {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(
    @contracts.json_object([
      ("result", outcome.result.to_json()),
      ("worktree", git_worktree_json(outcome.worktree)),
    ]),
  )
}

///|
async fn NodeHost::git_worktree_remove(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let path = match require_string(params, "path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let outcome = match
    self.executor.git_worktree_remove(
      path~,
      force=bool_param_or(params, "force", false),
      expected_head=optional_string(params, "expected_head"),
      expected_branch=optional_string(params, "expected_branch"),
    ) {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(
    @contracts.json_object([
      ("result", outcome.result.to_json()),
      ("removed", git_worktree_json(outcome.removed)),
    ]),
  )
}

///|
async fn NodeHost::git_read_output(
  self : NodeHost,
  request : @transport.HandlerRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let params = request.params
  let op_id = match require_string(params, "op_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match self.open_git() {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let stream = match @contracts.string_field(params, "stream") {
    Some(value) if value != "" => value
    _ => "stdout"
  }
  let max_bytes = int_param_or(params, "max_bytes", MAX_GIT_OUTPUT_CHARS)
    .max(1)
    .min(MAX_GIT_OUTPUT_CHARS)
  let outcome = match
    self.executor.git_read_output(
      op_id~,
      stream~,
      offset=int64_param_or(params, "offset", 0L),
      max_bytes~,
    ) {
    Ok(value) => value
    Err(error) => return Err(runtime_failure(error))
  }
  Ok(
    @contracts.json_object([
      ("op_id", @contracts.json_string(outcome.op_id)),
      ("stream", @contracts.json_string(outcome.stream)),
      ("offset", @contracts.json_int64(outcome.offset)),
      ("data", @contracts.json_string(outcome.data)),
      ("bytes", @contracts.json_int64(outcome.bytes)),
      ("eof", @contracts.json_bool(outcome.eof)),
      ("log_bytes", @contracts.json_int64(outcome.log_bytes)),
    ]),
  )
}
