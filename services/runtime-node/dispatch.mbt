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

///|
pub async fn NodeHost::dispatch(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
) -> Result[@json.Json, @contracts.RpcError] {
  let method = request.rpc_method
  match self.policy.authorize(method, self.workspace_root) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let crid = request.client_request_id
  match self.cache.lookup(method, crid) {
    Some(value) => return Ok(value)
    None => ()
  }
  let result = self.dispatch_inner(request, group)
  match result {
    Ok(value) => {
      self.cache.remember(method, crid, value)
      Ok(value)
    }
    Err(error) => Err(error)
  }
}

///|
async fn NodeHost::dispatch_inner(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
) -> Result[@json.Json, @contracts.RpcError] {
  let method = request.rpc_method
  if method == @contracts.METHOD_RUNTIME_EXEC_START {
    return self.exec_start(request, group)
  }
  if method == @contracts.METHOD_RUNTIME_EXEC_STATUS {
    return self.exec_status(request)
  }
  if method == @contracts.METHOD_RUNTIME_EXEC_CANCEL {
    return self.exec_cancel(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_READ {
    return self.fs_read(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_WRITE {
    return self.fs_write(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_LIST {
    return self.fs_list(request)
  }
  if method == @contracts.METHOD_RUNTIME_FS_STAT {
    return self.fs_stat(request)
  }
  if method == @contracts.METHOD_RUNTIME_PTY_OPEN {
    return self.pty_open(request, group)
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
  let spec = @runtime.CommandSpec::new(
    argv~,
    cwd=optional_string(params, "cwd"),
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
  match self.workspace.write_text(path, content) {
    Ok(_) => ()
    Err(message) => return Err(fs_failure(message))
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(path)),
      ("bytes", @contracts.json_int(content.length())),
      ("written", @contracts.json_bool(true)),
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
  let path = optional_string(request.params, "path")
  let stat = match self.workspace.stat(path) {
    Ok(value) => value
    Err(message) =>
      return Err(
        @contracts.RpcError::new(@contracts.ERR_INVALID_PARAMS, message),
      )
  }
  Ok(
    @contracts.json_object([
      ("path", @contracts.json_string(stat.path)),
      ("kind", @contracts.json_string(stat.kind)),
      ("size", @contracts.json_int64(stat.size)),
    ]),
  )
}

///|
async fn NodeHost::pty_open(
  self : NodeHost,
  request : @transport.HandlerRequest,
  group : @async.TaskGroup[Unit],
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
  let outcome = match
    self.executor.pty_open(
      group,
      session_id~,
      client_request_id~,
      argv~,
      cwd=optional_string(params, "cwd"),
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
