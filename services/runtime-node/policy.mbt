///|
/// Node-side policy gate (A1.2b injection point for A1.3b).
///
/// The node is an execution plane: it does not own org, task or approval
/// state and cannot answer Decisions. It only applies the policy snapshot the
/// primary gives it. Until A1.3b wires the snapshot, the gate fails closed:
/// every mutating method (exec start/cancel, fs write, PTY open/input/resize/
/// close, git branch/worktree mutations) is refused with `policy_stale`, while
/// read-only methods keep working.
///
/// A snapshot is a JSON object:
///
/// ```json
/// { "workspace_roots": ["/abs/path"], "allow_all": false }
/// ```
///
/// `workspace_roots` must contain the node's registered workspace root for
/// mutating calls to be allowed. `allow_all=true` is an explicit operator
/// override used by single-machine deployments and tests; it never bypasses
/// the rooted-workspace check in the runtime core itself.

///|
pub(all) struct PolicyGate {
  snapshot : @json.Json?
  allow_all : Bool
  roots : Array[String]
}

///|
pub fn PolicyGate::fail_closed() -> PolicyGate {
  { snapshot: None, allow_all: false, roots: [], }
}

///|
/// Explicit allow for one workspace root. This is the documented test and
/// single-machine override; it does not model an org policy decision.
pub fn PolicyGate::allow_workspace(workspace_root : String) -> PolicyGate {
  {
    snapshot: Some(
      @contracts.json_object([
        ("workspace_roots", @contracts.json_string_array([workspace_root])),
        ("allow_all", @contracts.json_bool(false)),
      ]),
    ),
    allow_all: false,
    roots: [workspace_root],
  }
}

///|
/// Install a policy snapshot. Malformed snapshots are rejected; callers must
/// keep the previous gate or fail closed rather than half-applying one.
pub fn PolicyGate::from_snapshot(snapshot : @json.Json) -> Result[PolicyGate, String] {
  let object = match @contracts.as_object(snapshot) {
    Some(value) => value
    None => return Err("policy snapshot must be a JSON object")
  }
  let allow_all = @contracts.bool_field_or(object, "allow_all", false)
  let roots : Array[String] = []
  match object.get("workspace_roots") {
    Some(value) =>
      match value {
        @json.Json::Array(items) => {
          if items.length() > 16 {
            return Err("policy snapshot has too many workspace roots")
          }
          for item in items {
            let root = match @contracts.as_string(item) {
              Some(text) => text
              None => return Err("workspace_roots must be strings")
            }
            if root.length() > 4096 || root.trim() == "" {
              return Err("workspace root is empty or too long")
            }
            roots.push(root)
          }
        }
        _ => return Err("workspace_roots must be an array")
      }
    None => ()
  }
  Ok({ snapshot: Some(snapshot), allow_all, roots })
}

///|
pub fn PolicyGate::has_snapshot(self : PolicyGate) -> Bool {
  self.snapshot is Some(_)
}

///|
/// Check one method. Read-only methods always pass; mutating methods need a
/// snapshot that grants the node's workspace root (or `allow_all`).
pub fn PolicyGate::authorize(
  self : PolicyGate,
  rpc_method : String,
  workspace_root : String,
) -> Result[Unit, @contracts.RpcError] {
  if !@contracts.runtime_method_mutates(rpc_method) {
    return Ok(())
  }
  if self.allow_all {
    return Ok(())
  }
  if self.snapshot is None {
    return Err(
      @contracts.RpcError::new(
        @transport.ERR_POLICY_STALE,
        "no policy snapshot is installed on this runtime; write denied",
      ),
    )
  }
  for root in self.roots {
    if root == workspace_root {
      return Ok(())
    }
  }
  Err(
    @contracts.RpcError::new(
      @transport.ERR_PATH_DENIED,
      "policy snapshot does not grant this workspace root",
    ),
  )
}
