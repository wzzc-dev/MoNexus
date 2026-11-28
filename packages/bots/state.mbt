///|
/// ADR-0017 §3 lifecycle guards. Every function is pure and rejects no-op
/// transitions so callers cannot report a state change that did not happen.

///|
pub fn bot_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  match from {
    "active" => to == @contracts.BOT_STATE_SUSPENDED ||
      to == @contracts.BOT_STATE_ARCHIVED
    "suspended" => to == @contracts.BOT_STATE_ACTIVE ||
      to == @contracts.BOT_STATE_ARCHIVED
    _ => false
  }
}

///|
pub fn agent_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  match from {
    "provisioning" => to == @contracts.AGENT_LIFECYCLE_ACTIVE ||
      to == @contracts.AGENT_LIFECYCLE_RETIRED
    "active" => to == @contracts.AGENT_LIFECYCLE_SUSPENDED ||
      to == @contracts.AGENT_LIFECYCLE_RETIRED
    "suspended" => to == @contracts.AGENT_LIFECYCLE_ACTIVE ||
      to == @contracts.AGENT_LIFECYCLE_RETIRED
    _ => false
  }
}

///|
pub fn chat_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  match (from, to) {
    ("active", "archived") => true
    ("archived", "active") => true
    _ => false
  }
}

///|
pub fn participant_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  match (from, to) {
    ("active", "removed") => true
    ("removed", "active") => true
    _ => false
  }
}

///|
pub fn agent_session_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  match from {
    "starting" => to == @contracts.AGENT_SESSION_STATE_ACTIVE ||
      to == @contracts.AGENT_SESSION_STATE_ENDING ||
      to == @contracts.AGENT_SESSION_STATE_FAILED
    "active" => to == @contracts.AGENT_SESSION_STATE_WAITING ||
      to == @contracts.AGENT_SESSION_STATE_ENDING ||
      to == @contracts.AGENT_SESSION_STATE_FAILED ||
      to == @contracts.AGENT_SESSION_STATE_LOST
    "waiting" => to == @contracts.AGENT_SESSION_STATE_ACTIVE ||
      to == @contracts.AGENT_SESSION_STATE_ENDING ||
      to == @contracts.AGENT_SESSION_STATE_FAILED ||
      to == @contracts.AGENT_SESSION_STATE_LOST
    "ending" => to == @contracts.AGENT_SESSION_STATE_ENDED ||
      to == @contracts.AGENT_SESSION_STATE_FAILED ||
      to == @contracts.AGENT_SESSION_STATE_LOST
    _ => false
  }
}

///|
pub fn project_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  match (from, to) {
    ("active", "archived") => true
    ("archived", "active") => true
    _ => false
  }
}

///|
pub fn membership_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  match (from, to) {
    ("active", "removed") => true
    ("removed", "active") => true
    _ => false
  }
}

///|
pub fn agent_session_is_terminal(state : String) -> Bool {
  state == @contracts.AGENT_SESSION_STATE_ENDED ||
  state == @contracts.AGENT_SESSION_STATE_FAILED ||
  state == @contracts.AGENT_SESSION_STATE_LOST
}

///|
pub fn agent_session_is_nonterminal(state : String) -> Bool {
  state == @contracts.AGENT_SESSION_STATE_STARTING ||
  state == @contracts.AGENT_SESSION_STATE_ACTIVE ||
  state == @contracts.AGENT_SESSION_STATE_WAITING ||
  state == @contracts.AGENT_SESSION_STATE_ENDING
}

// ---------------------------------------------------------------------------
// Archived / retired read-only guards
// ---------------------------------------------------------------------------

///|
pub fn bot_content_mutable(state : String) -> Bool {
  state != @contracts.BOT_STATE_ARCHIVED
}

///|
pub fn chat_content_mutable(state : String) -> Bool {
  state == @contracts.CHAT_STATE_ACTIVE
}

///|
pub fn project_content_mutable(state : String) -> Bool {
  state == @contracts.PROJECT_STATE_ACTIVE
}

///|
pub fn agent_metadata_mutable(state : String) -> Bool {
  state != @contracts.AGENT_LIFECYCLE_RETIRED
}

///|
pub fn bot_is_archived(state : String) -> Bool {
  state == @contracts.BOT_STATE_ARCHIVED
}

///|
pub fn chat_is_archived(state : String) -> Bool {
  state == @contracts.CHAT_STATE_ARCHIVED
}

///|
pub fn project_is_archived(state : String) -> Bool {
  state == @contracts.PROJECT_STATE_ARCHIVED
}
