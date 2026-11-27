///|
/// ADR-0017 I9 / §4.1: an approval belongs to one AgentSession and, when
/// applicable, one action. A new AgentSession never inherits an old grant.
pub(all) struct SessionApproval {
  decision_id : String
  agent_session_id : String
  action : String
  consumed : Bool
  run_id : String
}

///|
pub fn SessionApproval::new(
  decision_id~ : String,
  agent_session_id~ : String,
  action~ : String,
  run_id~ : String = "",
) -> SessionApproval {
  {
    decision_id,
    agent_session_id,
    action,
    consumed: false,
    run_id,
  }
}

///|
pub fn approval_applies_to_session(
  approval : SessionApproval,
  agent_session_id : String,
) -> Bool {
  approval.agent_session_id != "" &&
  approval.agent_session_id == agent_session_id
}

///|
pub fn approval_authorizes(
  approval : SessionApproval,
  agent_session_id : String,
  action : String,
) -> Bool {
  !approval.consumed &&
  approval.action == action &&
  approval_applies_to_session(approval, agent_session_id)
}
