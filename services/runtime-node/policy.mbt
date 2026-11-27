///|
/// Node-side policy gate (A1.3b).
///
/// The node is an execution plane: it does not own org, task or approval
/// state and cannot answer Decisions. It applies exactly the snapshot the
/// primary publishes, verifies its pinned hash before installing it, and
/// performs the same `@policy.evaluate` risk check the primary performs before
/// it ever executes a mutating request.
///
/// Modes:
///
/// - `snapshot` — a verified, typed `@policy.PolicySnapshot` is installed.
///   Every mutating entry point is classified locally; the result must be
///   `Allow` or carry a valid, one-time approval grant. A missing, stale or
///   unverifiable policy rejects or holds high-risk work (it is never
///   default-allowed), while low-risk read-only operations may proceed and
///   are audited.
/// - `override` — explicit operator trust (`--allow-workspace` or the legacy
///   JSON root grant). It deliberately skips the org risk check for
///   single-machine deployments and tests; it does not bypass the rooted
///   workspace checks in the runtime core. This is the same behavior A1.2b
///   shipped and is reported as `policy=override` by `runtime.probe`.
/// - `fail_closed` — no snapshot and no operator override. Read-only methods
///   keep working; every mutating method is refused with `policy_stale`.
///
/// The legacy JSON snapshot (`from_snapshot`) remains supported for callers
/// that only need the workspace-root gate; it is an override, not an org
/// policy.

///|
pub(all) struct PolicyGate {
  /// Legacy JSON root grant (`workspace_roots`, `allow_all`). Only used by the
  /// override mode.
  snapshot : @json.Json?
  allow_all : Bool
  roots : Array[String]
  /// Verified typed snapshot distributed by the primary. This is the only
  /// source that enables the full risk check.
  verified : @policy.PolicySnapshot?
}

///|
pub fn PolicyGate::fail_closed() -> PolicyGate {
  { snapshot: None, allow_all: false, roots: [], verified: None }
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
    verified: None,
  }
}

///|
/// Resolve legacy root grants before they are compared with the runtime's
/// execution root. The runtime root is already `realpath`-canonical, while a
/// caller may spell the same directory through a symlinked alias (macOS
/// `/var/folders/...` vs `/private/var/folders/...`). A root that does not
/// resolve keeps its original spelling, so an unknown root still fails
/// closed rather than silently matching.
pub async fn PolicyGate::canonicalized(self : PolicyGate) -> PolicyGate {
  if self.roots.is_empty() {
    return self
  }
  let roots : Array[String] = []
  for root in self.roots {
    let real = @fs.realpath(root) catch { _ => root }
    roots.push(real)
  }
  { ..self, roots }
}

///|
/// Install a legacy JSON snapshot. Malformed snapshots are rejected; callers
/// must keep the previous gate or fail closed rather than half-applying one.
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
  Ok({
    snapshot: Some(snapshot),
    allow_all,
    roots,
    verified: None,
  })
}

///|
/// Install a verified, typed policy snapshot. The caller must have verified
/// the pinned hash (`PolicyAnnouncement::verify`); a malformed snapshot can
/// never reach this constructor.
pub fn PolicyGate::from_policy_snapshot(
  snapshot : @policy.PolicySnapshot,
) -> PolicyGate {
  { snapshot: None, allow_all: false, roots: [], verified: Some(snapshot) }
}

///|
pub fn PolicyGate::has_snapshot(self : PolicyGate) -> Bool {
  self.verified is Some(_) || self.snapshot is Some(_)
}

///|
/// The typed snapshot, when the gate is in `snapshot` mode.
pub fn PolicyGate::verified_snapshot(
  self : PolicyGate,
) -> @policy.PolicySnapshot? {
  self.verified
}

///|
/// Stable mode label for `runtime.probe`: `snapshot`, `override` or
/// `fail_closed`.
pub fn PolicyGate::mode(self : PolicyGate) -> String {
  match self.verified {
    Some(_) => "snapshot"
    None =>
      if self.allow_all || !self.roots.is_empty() {
        "override"
      } else {
        "fail_closed"
      }
  }
}

///|
/// Check one method's workspace-root eligibility. Read-only methods always
/// pass; mutating methods need a verified snapshot (root containment is
/// enforced by the runtime core and `ExecutionRequest::validate`), a legacy
/// root grant for the node's workspace, or `allow_all`.
pub fn PolicyGate::authorize(
  self : PolicyGate,
  rpc_method : String,
  workspace_root : String,
) -> Result[Unit, @contracts.RpcError] {
  if self.verified is Some(_) {
    return Ok(())
  }
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
