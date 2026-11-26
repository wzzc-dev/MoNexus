///|
/// Reconcile decisions (ADR-0013 §3.5). Pure functions so the crash cases can
/// be tested without a daemon; the host scan performs the I/O and applies the
/// decision. Reconcile never creates an environment.

///|
pub enum ReconcileAction {
  Adopt
  DestroyIntent
  MarkDrift(String)
  Ignore
}

///|
pub fn reconcile_decision(
  record : @contracts.EnvironmentRecord,
  inspect : @docker.ContainerInspect?,
  labels_match : Bool,
  create_timed_out : Bool,
) -> ReconcileAction {
  if record.state == @contracts.ENVIRONMENT_STATE_DESTROYED ||
    record.state == @contracts.ENVIRONMENT_STATE_FAILED {
    return Ignore
  }
  match inspect {
    None =>
      if record.state == @contracts.ENVIRONMENT_STATE_CREATING {
        if create_timed_out {
          MarkDrift("timed-out create intent has no container")
        } else {
          Ignore
        }
      } else {
        MarkDrift("container is missing")
      }
    Some(value) =>
      if !labels_match {
        MarkDrift("container labels do not match; container left untouched")
      } else if record.state == @contracts.ENVIRONMENT_STATE_CREATING {
        // A timed-out create is only destroyed when the container is still
        // incomplete. A complete, running container is adopted rather than
        // recreating it (ADR-0013 §3.5).
        if create_timed_out && !value.running {
          DestroyIntent
        } else {
          Adopt
        }
      } else {
        Adopt
      }
  }
}

///|
pub fn managed_name_matches(
  record : @contracts.EnvironmentRecord,
  name : String,
) -> Bool {
  name == "monexus-env-" + record.id
}

///|
pub const CREATE_INTENT_TIMEOUT_MS : Int64 = 900_000

///|
pub fn create_intent_timed_out(age_ms : Int64) -> Bool {
  age_ms >= CREATE_INTENT_TIMEOUT_MS
}
