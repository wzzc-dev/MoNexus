///|
/// Workspace / worktree / lease / terminal contracts (M3).
///
/// The same JSON shapes are used by the local and SSH providers: a workspace
/// record only stores a machine id (`""` means local) and a root path; every
/// file operation sends a workspace id plus a workspace-relative path. The
/// desktop never learns whether the root is local or remote.

// ---------------------------------------------------------------------------
// RPC methods
// ---------------------------------------------------------------------------

///|
pub const METHOD_WORKSPACE_OPEN : String = "workspace.open"

///|
pub const METHOD_WORKSPACE_LIST : String = "workspace.list"

///|
pub const METHOD_WORKSPACE_LIST_FILES : String = "workspace.listFiles"

///|
pub const METHOD_WORKSPACE_STAT : String = "workspace.stat"

///|
pub const METHOD_WORKSPACE_READ : String = "workspace.read"

///|
pub const METHOD_WORKSPACE_WRITE : String = "workspace.write"

///|
pub const METHOD_WORKSPACE_MOVE : String = "workspace.move"

///|
pub const METHOD_WORKSPACE_REMOVE : String = "workspace.remove"

///|
pub const METHOD_WORKSPACE_GIT_STATUS : String = "workspace.gitStatus"

///|
pub const METHOD_WORKSPACE_GIT_DIFF : String = "workspace.gitDiff"

///|
pub const METHOD_WORKSPACE_CLOSE : String = "workspace.close"

///|
pub const METHOD_WORKTREE_CREATE : String = "worktree.create"

///|
pub const METHOD_WORKTREE_REMOVE : String = "worktree.remove"

///|
pub const METHOD_WORKTREE_LIST : String = "worktree.list"

///|
pub const METHOD_LEASE_ACQUIRE : String = "lease.acquire"

///|
pub const METHOD_LEASE_RELEASE : String = "lease.release"

///|
pub const METHOD_LEASE_LIST : String = "lease.list"

///|
pub const METHOD_TERMINAL_OPEN : String = "terminal.open"

///|
pub const METHOD_TERMINAL_WRITE : String = "terminal.write"

///|
pub const METHOD_TERMINAL_RESIZE : String = "terminal.resize"

///|
pub const METHOD_TERMINAL_READ : String = "terminal.read"

///|
pub const METHOD_TERMINAL_CLOSE : String = "terminal.close"

///|
pub const TERMINAL_MIN_SIZE : Int = 1

///|
pub const TERMINAL_MAX_SIZE : Int = 10_000

///|
/// The PTY size is part of the wire contract, so validation lives here rather
/// than in each transport. The upper bound matches the local PTY runtime.
pub fn terminal_size_is_valid(rows : Int, cols : Int) -> Bool {
  rows >= TERMINAL_MIN_SIZE &&
  rows <= TERMINAL_MAX_SIZE &&
  cols >= TERMINAL_MIN_SIZE &&
  cols <= TERMINAL_MAX_SIZE
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

///|
pub const EVENT_WORKSPACE_OPENED : String = "workspace.opened"

///|
pub const EVENT_WORKSPACE_CHANGED : String = "workspace.changed"

///|
pub const EVENT_WORKSPACE_CLOSED : String = "workspace.closed"

///|
pub const EVENT_WORKTREE_CREATED : String = "worktree.created"

///|
pub const EVENT_WORKTREE_READY : String = "worktree.ready"

///|
pub const EVENT_WORKTREE_ARCHIVED : String = "worktree.archived"

///|
pub const EVENT_LEASE_ACQUIRED : String = "lease.acquired"

///|
pub const EVENT_LEASE_RELEASED : String = "lease.released"

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

///|
pub const WORKSPACE_ERR_INVALID : String = "invalid"

///|
pub const WORKSPACE_ERR_NOT_FOUND : String = "not_found"

///|
pub const WORKSPACE_ERR_CONFLICT : String = "conflict"

///|
pub const WORKSPACE_ERR_UNAUTHORIZED : String = "unauthorized"

///|
pub const WORKSPACE_ERR_TIMEOUT : String = "timeout"

///|
pub const WORKSPACE_ERR_UNREACHABLE : String = "unreachable"

///|
pub const WORKSPACE_ERR_HOST_KEY : String = "host_key"

///|
pub const WORKSPACE_ERR_REMOTE : String = "remote"

///|
pub const WORKSPACE_ERR_INTERNAL : String = "internal"

///|
pub const WORKSPACE_ERR_UNSUPPORTED : String = "unsupported"

///|
pub fn workspace_error_label(kind : String) -> String {
  match kind {
    "invalid" => "InvalidRequest"
    "not_found" => "NotFound"
    "conflict" => "Conflict"
    "unauthorized" => "Unauthorized"
    "timeout" => "Timeout"
    "unreachable" => "Unreachable"
    "host_key" => "HostKeyRejected"
    "remote" => "RemoteError"
    "unsupported" => "Unsupported"
    _ => "Internal"
  }
}

///|
pub fn workspace_error(
  kind : String,
  message : String,
  detail? : String,
) -> RpcError {
  let entries : Array[(String, @json.Json)] = [
    ("kind", json_string(kind)),
    ("reason", json_string(message)),
  ]
  match detail {
    Some(value) =>
      if value.trim() != "" {
        entries.push(("detail", json_string(value)))
      }
    None => ()
  }
  RpcError::new(
    ERR_HOST,
    workspace_error_label(kind) + ": " + message,
    data=json_object(entries),
  )
}

///|
pub fn workspace_error_text(error : RpcError) -> String {
  let base = error.message
  let detail = match error.data {
    Some(@json.Json::Object(object)) =>
      match string_field(object, "detail") {
        Some(value) => value
        None => ""
      }
    _ => ""
  }
  if detail.trim() == "" {
    return base
  }
  let first_line = match detail.split_once("\n") {
    Some((line, _)) => line.to_owned()
    None => detail
  }
  base + " (" + first_line.trim().to_owned() + ")"
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

///|
pub const WORKSPACE_KIND_LOCAL : String = "local"

///|
pub const WORKSPACE_KIND_SSH : String = "ssh"

///|
pub const WORKSPACE_STATE_AVAILABLE : String = "available"

///|
pub const WORKSPACE_STATE_CLOSED : String = "closed"

///|
pub const WORKTREE_STATE_READY : String = "ready"

///|
pub const WORKTREE_STATE_ARCHIVED : String = "archived"

///|
pub(all) struct WorkspaceRecord {
  id : String
  machine_id : String
  kind : String
  root : String
  name : String
  git_root : String
  is_git : Bool
  state : String
  created_at : String
  updated_at : String
}

///|
pub fn WorkspaceRecord::to_json(self : WorkspaceRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("machine_id", json_string(self.machine_id)),
    ("kind", json_string(self.kind)),
    ("root", json_string(self.root)),
    ("name", json_string(self.name)),
    ("git_root", json_string(self.git_root)),
    ("is_git", json_bool(self.is_git)),
    ("state", json_string(self.state)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
  ])
}

///|
pub fn workspace_record_from_json(
  json : @json.Json,
) -> WorkspaceRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  Some({
    id,
    machine_id: string_field_or(object, "machine_id", ""),
    kind: string_field_or(object, "kind", WORKSPACE_KIND_LOCAL),
    root: string_field_or(object, "root", ""),
    name: string_field_or(object, "name", ""),
    git_root: string_field_or(object, "git_root", ""),
    is_git: bool_field_or(object, "is_git", false),
    state: string_field_or(object, "state", WORKSPACE_STATE_AVAILABLE),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
  })
}

///|
pub fn WorkspaceRecord::target_label(self : WorkspaceRecord) -> String {
  if self.machine_id == "" {
    "local"
  } else {
    self.machine_id
  }
}

///|
pub(all) struct WorktreeRecord {
  id : String
  workspace_id : String
  machine_id : String
  branch : String
  path : String
  base : String
  state : String
  created_at : String
  updated_at : String
}

///|
pub fn WorktreeRecord::to_json(self : WorktreeRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("workspace_id", json_string(self.workspace_id)),
    ("machine_id", json_string(self.machine_id)),
    ("branch", json_string(self.branch)),
    ("path", json_string(self.path)),
    ("base", json_string(self.base)),
    ("state", json_string(self.state)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
  ])
}

///|
pub fn worktree_record_from_json(
  json : @json.Json,
) -> WorktreeRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  Some({
    id,
    workspace_id: string_field_or(object, "workspace_id", ""),
    machine_id: string_field_or(object, "machine_id", ""),
    branch: string_field_or(object, "branch", ""),
    path: string_field_or(object, "path", ""),
    base: string_field_or(object, "base", ""),
    state: string_field_or(object, "state", WORKTREE_STATE_READY),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
  })
}

///|
pub(all) struct LeaseRecord {
  id : String
  target_kind : String
  target_id : String
  holder : String
  created_at : String
}

///|
pub fn LeaseRecord::to_json(self : LeaseRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("target_kind", json_string(self.target_kind)),
    ("target_id", json_string(self.target_id)),
    ("holder", json_string(self.holder)),
    ("created_at", json_string(self.created_at)),
  ])
}

///|
pub fn lease_record_from_json(json : @json.Json) -> LeaseRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  Some({
    id,
    target_kind: string_field_or(object, "target_kind", ""),
    target_id: string_field_or(object, "target_id", ""),
    holder: string_field_or(object, "holder", ""),
    created_at: string_field_or(object, "created_at", ""),
  })
}

///|
pub(all) struct WorkspaceEntry {
  name : String
  path : String
  kind : String
  is_dir : Bool
  size : Int64
}

///|
pub fn WorkspaceEntry::to_json(self : WorkspaceEntry) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("path", json_string(self.path)),
    ("kind", json_string(self.kind)),
    ("is_dir", json_bool(self.is_dir)),
    ("size", json_int64(self.size)),
  ])
}

///|
pub fn workspace_entry_from_json(json : @json.Json) -> WorkspaceEntry? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let name = match string_field(object, "name") {
    Some(value) => value
    None => return None
  }
  Some({
    name,
    path: string_field_or(object, "path", name),
    kind: string_field_or(object, "kind", "file"),
    is_dir: bool_field_or(object, "is_dir", false),
    size: int64_field_or(object, "size", 0L),
  })
}

///|
pub(all) struct WorkspaceStat {
  path : String
  kind : String
  size : Int64
}

///|
pub fn WorkspaceStat::to_json(self : WorkspaceStat) -> @json.Json {
  json_object([
    ("path", json_string(self.path)),
    ("kind", json_string(self.kind)),
    ("size", json_int64(self.size)),
  ])
}

///|
pub fn workspace_stat_from_json(json : @json.Json) -> WorkspaceStat? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let path = match string_field(object, "path") {
    Some(value) => value
    None => return None
  }
  Some({
    path,
    kind: string_field_or(object, "kind", "file"),
    size: int64_field_or(object, "size", 0L),
  })
}

///|
pub(all) struct GitChange {
  path : String
  status : String
  index_status : String
  worktree_status : String
}

///|
pub fn GitChange::to_json(self : GitChange) -> @json.Json {
  json_object([
    ("path", json_string(self.path)),
    ("status", json_string(self.status)),
    ("index_status", json_string(self.index_status)),
    ("worktree_status", json_string(self.worktree_status)),
  ])
}

///|
pub fn git_change_from_json(json : @json.Json) -> GitChange? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let path = match string_field(object, "path") {
    Some(value) => value
    None => return None
  }
  Some({
    path,
    status: string_field_or(object, "status", "??"),
    index_status: string_field_or(object, "index_status", " "),
    worktree_status: string_field_or(object, "worktree_status", " "),
  })
}

///|
pub(all) struct GitStatus {
  is_git : Bool
  branch : String
  upstream : String
  ahead : Int
  behind : Int
  changes : Array[GitChange]
}

///|
pub fn GitStatus::to_json(self : GitStatus) -> @json.Json {
  let changes : Array[@json.Json] = []
  for change in self.changes {
    changes.push(change.to_json())
  }
  json_object([
    ("is_git", json_bool(self.is_git)),
    ("branch", json_string(self.branch)),
    ("upstream", json_string(self.upstream)),
    ("ahead", json_int(self.ahead)),
    ("behind", json_int(self.behind)),
    ("changes", json_array(changes)),
  ])
}

///|
pub fn git_status_from_json(json : @json.Json) -> GitStatus? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let changes : Array[GitChange] = []
  match object.get("changes") {
    Some(@json.Json::Array(values)) =>
      for value in values {
        match git_change_from_json(value) {
          Some(change) => changes.push(change)
          None => ()
        }
      }
    _ => ()
  }
  Some({
    is_git: bool_field_or(object, "is_git", false),
    branch: string_field_or(object, "branch", ""),
    upstream: string_field_or(object, "upstream", ""),
    ahead: int_field_or(object, "ahead", 0),
    behind: int_field_or(object, "behind", 0),
    changes,
  })
}

///|
pub(all) struct GitDiff {
  path : String
  cached : Bool
  range : String
  text : String
  truncated : Bool
}

///|
pub fn GitDiff::to_json(self : GitDiff) -> @json.Json {
  json_object([
    ("path", json_string(self.path)),
    ("cached", json_bool(self.cached)),
    ("range", json_string(self.range)),
    ("text", json_string(self.text)),
    ("truncated", json_bool(self.truncated)),
  ])
}

///|
pub fn git_diff_from_json(json : @json.Json) -> GitDiff? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    path: string_field_or(object, "path", ""),
    cached: bool_field_or(object, "cached", false),
    range: string_field_or(object, "range", ""),
    text: string_field_or(object, "text", ""),
    truncated: bool_field_or(object, "truncated", false),
  })
}

///|
pub(all) struct TerminalRead {
  session_id : String
  cursor : Int64
  text : String
  eof : Bool
}

///|
pub fn TerminalRead::to_json(self : TerminalRead) -> @json.Json {
  json_object([
    ("session_id", json_string(self.session_id)),
    ("cursor", json_int64(self.cursor)),
    ("text", json_string(self.text)),
    ("eof", json_bool(self.eof)),
  ])
}

///|
pub fn terminal_read_from_json(json : @json.Json) -> TerminalRead? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let session_id = match string_field(object, "session_id") {
    Some(value) => value
    None => return None
  }
  Some({
    session_id,
    cursor: int64_field_or(object, "cursor", 0L),
    text: string_field_or(object, "text", ""),
    eof: bool_field_or(object, "eof", false),
  })
}

///|
pub(all) struct TerminalOpenResult {
  session_id : String
  workspace_id : String
  cursor : Int64
  text : String
  eof : Bool
}

///|
pub fn TerminalOpenResult::to_json(self : TerminalOpenResult) -> @json.Json {
  json_object([
    ("session_id", json_string(self.session_id)),
    ("workspace_id", json_string(self.workspace_id)),
    ("cursor", json_int64(self.cursor)),
    ("text", json_string(self.text)),
    ("eof", json_bool(self.eof)),
  ])
}

///|
pub fn terminal_open_from_json(
  json : @json.Json,
) -> TerminalOpenResult? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let session_id = match string_field(object, "session_id") {
    Some(value) => value
    None => return None
  }
  Some({
    session_id,
    workspace_id: string_field_or(object, "workspace_id", ""),
    cursor: int64_field_or(object, "cursor", 0L),
    text: string_field_or(object, "text", ""),
    eof: bool_field_or(object, "eof", false),
  })
}

///|
pub(all) struct TerminalResizeResult {
  session_id : String
  rows : Int
  cols : Int
}

///|
pub fn TerminalResizeResult::to_json(
  self : TerminalResizeResult,
) -> @json.Json {
  json_object([
    ("session_id", json_string(self.session_id)),
    ("rows", json_int(self.rows)),
    ("cols", json_int(self.cols)),
  ])
}

///|
pub fn terminal_resize_from_json(
  json : @json.Json,
) -> TerminalResizeResult? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let session_id = match string_field(object, "session_id") {
    Some(value) if value != "" => value
    _ => return None
  }
  let rows = match int_field(object, "rows") {
    Some(value) => value
    None => return None
  }
  let cols = match int_field(object, "cols") {
    Some(value) => value
    None => return None
  }
  if !terminal_size_is_valid(rows, cols) {
    return None
  }
  Some({ session_id, rows, cols })
}

// ---------------------------------------------------------------------------
// Param builders and parsers
// ---------------------------------------------------------------------------

///|
pub fn workspace_open_params(
  client_request_id : String,
  machine_id : String,
  root : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([
    ("client_request_id", json_string(client_request_id)),
    ("target", json_string(if machine_id == "" { "local" } else { machine_id })),
    ("root", json_string(root)),
  ])
  params
}

///|
pub fn workspace_open_target(params : Map[String, @json.Json]) -> String {
  match string_field(params, "target") {
    Some(value) if value != "" && value != "local" => value
    _ =>
      // Shell tests may use the record field name directly; the desktop uses
      // workspace_open_params, which writes `target`.
      string_field_or(params, "machine_id", "")
  }
}

///|
pub fn workspace_root_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "root") {
    Some(value) if value.trim() != "" => Ok(value.trim().to_owned())
    _ => Err("missing root")
  }
}

///|
pub fn workspace_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "workspace_id") {
    Some(value) if value.trim() != "" => Ok(value)
    _ => Err("missing workspace_id")
  }
}

///|
pub fn workspace_path_param(
  params : Map[String, @json.Json],
) -> String {
  string_field_or(params, "path", "")
}

///|
pub fn workspace_content_param(
  params : Map[String, @json.Json],
) -> String {
  string_field_or(params, "content", "")
}

///|
pub fn workspace_registry_list_params(
  client_request_id : String,
) -> Map[String, @json.Json] {
  Map([("client_request_id", json_string(client_request_id))])
}

///|
pub fn workspace_list_params(
  client_request_id : String,
  workspace_id : String,
  path : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
    ("path", json_string(path)),
  ])
}

///|
pub fn workspace_read_params(
  client_request_id : String,
  workspace_id : String,
  path : String,
) -> Map[String, @json.Json] {
  workspace_list_params(client_request_id, workspace_id, path)
}

///|
pub fn workspace_write_params(
  client_request_id : String,
  workspace_id : String,
  path : String,
  content : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
    ("path", json_string(path)),
    ("content", json_string(content)),
  ])
}

///|
pub fn workspace_move_params(
  client_request_id : String,
  workspace_id : String,
  from_path : String,
  to_path : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
    ("from", json_string(from_path)),
    ("to", json_string(to_path)),
  ])
}

///|
pub fn workspace_remove_params(
  client_request_id : String,
  workspace_id : String,
  path : String,
) -> Map[String, @json.Json] {
  workspace_list_params(client_request_id, workspace_id, path)
}

///|
pub fn workspace_git_status_params(
  client_request_id : String,
  workspace_id : String,
  worktree_id~ : String = "",
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
    ("worktree_id", json_string(worktree_id)),
  ])
}

///|
pub fn workspace_git_diff_params(
  client_request_id : String,
  workspace_id : String,
  path : String,
  cached : Bool,
  range : String,
  worktree_id~ : String = "",
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
    ("path", json_string(path)),
    ("cached", json_bool(cached)),
    ("range", json_string(range)),
    ("worktree_id", json_string(worktree_id)),
  ])
}

///|
pub fn worktree_create_params(
  client_request_id : String,
  workspace_id : String,
  branch : String,
  path : String,
  base : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
    ("branch", json_string(branch)),
    ("path", json_string(path)),
    ("base", json_string(base)),
  ])
}

///|
pub fn worktree_remove_params(
  client_request_id : String,
  worktree_id : String,
  force : Bool,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("worktree_id", json_string(worktree_id)),
    ("force", json_bool(force)),
  ])
}

///|
pub fn worktree_list_params(
  client_request_id : String,
  workspace_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
  ])
}

///|
pub fn lease_acquire_params(
  client_request_id : String,
  target_kind : String,
  target_id : String,
  holder : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("target_kind", json_string(target_kind)),
    ("target_id", json_string(target_id)),
    ("holder", json_string(holder)),
  ])
}

///|
pub fn lease_release_params(
  client_request_id : String,
  lease_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("lease_id", json_string(lease_id)),
  ])
}

///|
pub fn lease_list_params(
  client_request_id : String,
) -> Map[String, @json.Json] {
  Map([("client_request_id", json_string(client_request_id))])
}

///|
pub fn terminal_open_params(
  client_request_id : String,
  workspace_id : String,
  command : String,
  rows : Int,
  cols : Int,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("workspace_id", json_string(workspace_id)),
    ("command", json_string(command)),
    ("rows", json_int(rows)),
    ("cols", json_int(cols)),
  ])
}

///|
pub fn terminal_write_params(
  client_request_id : String,
  session_id : String,
  data : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
    ("data", json_string(data)),
  ])
}

///|
pub fn terminal_resize_params(
  client_request_id : String,
  session_id : String,
  rows : Int,
  cols : Int,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
    ("rows", json_int(rows)),
    ("cols", json_int(cols)),
  ])
}

///|
pub fn terminal_read_params(
  client_request_id : String,
  session_id : String,
  cursor : Int64,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
    ("cursor", json_int64(cursor)),
  ])
}

///|
pub fn terminal_close_params(
  client_request_id : String,
  session_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
  ])
}

// ---------------------------------------------------------------------------
// Result builders / parsers
// ---------------------------------------------------------------------------

///|
pub fn workspace_result(record : WorkspaceRecord) -> @json.Json {
  json_object([("workspace", record.to_json())])
}

///|
pub fn workspace_result_record(
  json : @json.Json,
) -> Result[WorkspaceRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("workspace result is not an object")
  }
  match object.get("workspace") {
    Some(value) =>
      match workspace_record_from_json(value) {
        Some(record) => Ok(record)
        None => Err("workspace result is malformed")
      }
    None => Err("workspace result has no workspace")
  }
}

///|
pub fn workspace_list_result(
  workspaces : Array[WorkspaceRecord],
) -> @json.Json {
  let items : Array[@json.Json] = []
  for record in workspaces {
    items.push(record.to_json())
  }
  json_object([("workspaces", json_array(items))])
}

///|
pub fn workspace_list_from_json(
  json : @json.Json,
) -> Result[Array[WorkspaceRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("workspace.list result is not an object")
  }
  let items = match object.get("workspaces") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("workspace.list result has no workspaces array")
  }
  let out : Array[WorkspaceRecord] = []
  for item in items {
    match workspace_record_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("workspace.list contains a malformed record")
    }
  }
  Ok(out)
}

///|
pub fn workspace_entries_result(
  path : String,
  entries : Array[WorkspaceEntry],
) -> @json.Json {
  let items : Array[@json.Json] = []
  for entry in entries {
    items.push(entry.to_json())
  }
  json_object([("path", json_string(path)), ("entries", json_array(items))])
}

///|
pub fn workspace_entries_from_json(
  json : @json.Json,
) -> Result[Array[WorkspaceEntry], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("workspace.list result is not an object")
  }
  let items = match object.get("entries") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("workspace.list result has no entries array")
  }
  let out : Array[WorkspaceEntry] = []
  for item in items {
    match workspace_entry_from_json(item) {
      Some(entry) => out.push(entry)
      None => return Err("workspace.list contains a malformed entry")
    }
  }
  Ok(out)
}

///|
pub fn workspace_text_result(
  path : String,
  text : String,
) -> @json.Json {
  json_object([("path", json_string(path)), ("text", json_string(text))])
}

///|
pub fn workspace_text_from_json(
  json : @json.Json,
) -> Result[String, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("workspace.read result is not an object")
  }
  match string_field(object, "text") {
    Some(value) => Ok(value)
    None => Err("workspace.read result has no text")
  }
}

///|
pub fn workspace_ack_result(workspace_id : String, path : String) -> @json.Json {
  json_object([
    ("workspace_id", json_string(workspace_id)),
    ("path", json_string(path)),
    ("ok", json_bool(true)),
  ])
}

///|
pub fn terminal_resize_result(
  session_id : String,
  rows : Int,
  cols : Int,
) -> @json.Json {
  TerminalResizeResult::{ session_id, rows, cols }.to_json()
}

///|
pub fn workspace_stat_result(stat : WorkspaceStat) -> @json.Json {
  json_object([("stat", stat.to_json())])
}

///|
pub fn workspace_stat_result_value(
  json : @json.Json,
) -> Result[WorkspaceStat, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("workspace.stat result is not an object")
  }
  match object.get("stat") {
    Some(value) =>
      match workspace_stat_from_json(value) {
        Some(stat) => Ok(stat)
        None => Err("workspace.stat result is malformed")
      }
    None => Err("workspace.stat result has no stat")
  }
}

///|
pub fn git_status_result(status : GitStatus) -> @json.Json {
  json_object([("git_status", status.to_json())])
}

///|
pub fn git_status_result_value(
  json : @json.Json,
) -> Result[GitStatus, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("workspace.gitStatus result is not an object")
  }
  match object.get("git_status") {
    Some(value) =>
      match git_status_from_json(value) {
        Some(status) => Ok(status)
        None => Err("workspace.gitStatus result is malformed")
      }
    None => Err("workspace.gitStatus result has no git_status")
  }
}

///|
pub fn git_diff_result(diff : GitDiff) -> @json.Json {
  json_object([("git_diff", diff.to_json())])
}

///|
pub fn git_diff_result_value(
  json : @json.Json,
) -> Result[GitDiff, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("workspace.gitDiff result is not an object")
  }
  match object.get("git_diff") {
    Some(value) =>
      match git_diff_from_json(value) {
        Some(diff) => Ok(diff)
        None => Err("workspace.gitDiff result is malformed")
      }
    None => Err("workspace.gitDiff result has no git_diff")
  }
}

///|
pub fn worktree_result(record : WorktreeRecord) -> @json.Json {
  json_object([("worktree", record.to_json())])
}

///|
pub fn worktree_result_record(
  json : @json.Json,
) -> Result[WorktreeRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("worktree result is not an object")
  }
  match object.get("worktree") {
    Some(value) =>
      match worktree_record_from_json(value) {
        Some(record) => Ok(record)
        None => Err("worktree result is malformed")
      }
    None => Err("worktree result has no worktree")
  }
}

///|
pub fn worktree_list_result(
  worktrees : Array[WorktreeRecord],
) -> @json.Json {
  let items : Array[@json.Json] = []
  for record in worktrees {
    items.push(record.to_json())
  }
  json_object([("worktrees", json_array(items))])
}

///|
pub fn worktree_list_from_json(
  json : @json.Json,
) -> Result[Array[WorktreeRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("worktree.list result is not an object")
  }
  let items = match object.get("worktrees") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("worktree.list result has no worktrees array")
  }
  let out : Array[WorktreeRecord] = []
  for item in items {
    match worktree_record_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("worktree.list contains a malformed record")
    }
  }
  Ok(out)
}

///|
pub fn lease_result(record : LeaseRecord) -> @json.Json {
  json_object([("lease", record.to_json())])
}

///|
pub fn lease_result_record(
  json : @json.Json,
) -> Result[LeaseRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("lease result is not an object")
  }
  match object.get("lease") {
    Some(value) =>
      match lease_record_from_json(value) {
        Some(record) => Ok(record)
        None => Err("lease result is malformed")
      }
    None => Err("lease result has no lease")
  }
}

///|
pub fn lease_list_result(leases : Array[LeaseRecord]) -> @json.Json {
  let items : Array[@json.Json] = []
  for record in leases {
    items.push(record.to_json())
  }
  json_object([("leases", json_array(items))])
}

///|
pub fn lease_list_from_json(
  json : @json.Json,
) -> Result[Array[LeaseRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("lease.list result is not an object")
  }
  let items = match object.get("leases") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("lease.list result has no leases array")
  }
  let out : Array[LeaseRecord] = []
  for item in items {
    match lease_record_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("lease.list contains a malformed record")
    }
  }
  Ok(out)
}

// ---------------------------------------------------------------------------
// Event helpers
// ---------------------------------------------------------------------------

///|
pub fn workspace_event_payload(record : WorkspaceRecord) -> @json.Json {
  json_object([
    ("workspace_id", json_string(record.id)),
    ("workspace", record.to_json()),
  ])
}

///|
pub fn workspace_closed_payload(workspace_id : String) -> @json.Json {
  json_object([("workspace_id", json_string(workspace_id))])
}

///|
pub fn workspace_changed_payload(
  workspace_id : String,
  path : String,
  operation : String,
) -> @json.Json {
  json_object([
    ("workspace_id", json_string(workspace_id)),
    ("path", json_string(path)),
    ("operation", json_string(operation)),
  ])
}

///|
pub fn worktree_event_payload(record : WorktreeRecord) -> @json.Json {
  json_object([
    ("worktree_id", json_string(record.id)),
    ("worktree", record.to_json()),
  ])
}

///|
pub fn worktree_archived_payload(worktree_id : String) -> @json.Json {
  json_object([("worktree_id", json_string(worktree_id))])
}

///|
pub fn lease_event_payload(record : LeaseRecord) -> @json.Json {
  json_object([
    ("lease_id", json_string(record.id)),
    ("lease", record.to_json()),
  ])
}

///|
pub fn lease_released_payload(lease_id : String) -> @json.Json {
  json_object([("lease_id", json_string(lease_id))])
}

///|
fn event_payload_record(
  event : EventEnvelope,
  key : String,
) -> @json.Json? {
  match event.payload {
    @json.Json::Object(object) => object.get(key)
    _ => None
  }
}

///|
pub fn workspace_event_record(
  event : EventEnvelope,
) -> WorkspaceRecord? {
  match event_payload_record(event, "workspace") {
    Some(value) => workspace_record_from_json(value)
    None => None
  }
}

///|
pub fn worktree_event_record(
  event : EventEnvelope,
) -> WorktreeRecord? {
  match event_payload_record(event, "worktree") {
    Some(value) => worktree_record_from_json(value)
    None => None
  }
}

///|
pub fn lease_event_record(event : EventEnvelope) -> LeaseRecord? {
  match event_payload_record(event, "lease") {
    Some(value) => lease_record_from_json(value)
    None => None
  }
}

///|
fn event_payload_id(event : EventEnvelope, key : String) -> String? {
  match event.payload {
    @json.Json::Object(object) =>
      match object.get(key) {
        Some(@json.Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
pub fn workspace_closed_id(event : EventEnvelope) -> String? {
  event_payload_id(event, "workspace_id")
}

///|
pub fn worktree_archived_id(event : EventEnvelope) -> String? {
  event_payload_id(event, "worktree_id")
}

///|
pub fn lease_released_id(event : EventEnvelope) -> String? {
  event_payload_id(event, "lease_id")
}
