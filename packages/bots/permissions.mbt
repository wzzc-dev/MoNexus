///|
/// ADR-0017 §4.1 effective-permission intersection.
///
/// Every level is an allowlist. The result is formed by intersection only, so
/// an Agent, task, tool or skill can narrow the result but never widen the
/// organization policy, Bot ceiling or Project policy. Membership is a hard
/// gate for a project-scoped Chat.
pub(all) struct PermissionRequest {
  org_policy : Array[String]
  bot_ceiling : Array[String]
  project_id : String
  project_policy : Array[String]
  project_membership_active : Bool
  agent_scope : Array[String]
  task_scope : Array[String]
  session_scope : Array[String]
  tool_allowlist : Array[String]
  skill_allowlist : Array[String]
}

///|
pub fn PermissionRequest::new(
  org_policy~ : Array[String],
  bot_ceiling~ : Array[String],
  agent_scope~ : Array[String],
  task_scope~ : Array[String],
  session_scope~ : Array[String],
  tool_allowlist~ : Array[String],
  skill_allowlist~ : Array[String],
  project_id~ : String = "",
  project_policy~ : Array[String] = [],
  project_membership_active~ : Bool = false,
) -> PermissionRequest {
  {
    org_policy,
    bot_ceiling,
    project_id,
    project_policy,
    project_membership_active,
    agent_scope,
    task_scope,
    session_scope,
    tool_allowlist,
    skill_allowlist,
  }
}

///|
fn permission_intersect(
  left : Array[String],
  right : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  for item in left {
    if right.contains(item) && !out.contains(item) {
      out.push(item)
    }
  }
  out
}

///|
pub fn effective_permission(
  request : PermissionRequest,
) -> Result[Array[String], String] {
  if request.project_id != "" && !request.project_membership_active {
    return Err("project membership is required for a project-scoped request")
  }
  let mut allowed = permission_intersect(
    request.org_policy,
    request.bot_ceiling,
  )
  if request.project_id != "" {
    allowed = permission_intersect(allowed, request.project_policy)
  }
  allowed = permission_intersect(allowed, request.agent_scope)
  allowed = permission_intersect(allowed, request.task_scope)
  allowed = permission_intersect(allowed, request.session_scope)
  allowed = permission_intersect(allowed, request.tool_allowlist)
  allowed = permission_intersect(allowed, request.skill_allowlist)
  Ok(allowed)
}

///|
pub fn permission_covers(
  allowed : Array[String],
  requested : String,
) -> Bool {
  allowed.contains(requested)
}
