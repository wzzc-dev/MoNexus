///|
/// Stable reason codes for the Docker environment provider (ADR-0013 §3).
///
/// A2.1/A2.2 surface these labels in plan/doctor diagnostics, so they are part
/// of the observable contract and must not be renamed without a migration.
/// Details are constants plus field names only: environment values, host
/// secrets and container output never reach an error string.
pub(all) enum DockerErrorCode {
  DockerMissing
  DockerProbeTimeout
  DockerUnavailable
  DockerInfoInvalid
  DockerVersionUnsupported
  DockerFlagUnsupported
  InvalidEnvironmentId
  InvalidPrimaryId
  InvalidWorkspaceId
  InvalidRecipeHash
  InvalidRoot
  ForbiddenRoot
  RootsOverlap
  InvalidContainerPath
  InvalidEnvName
  EnvNameNotAllowed
  EnvNameDuplicate
  EnvValueInvalid
  EnvFileInvalid
  EnvFileInsecure
  EnvFileWriteFailed
  EnvFileRemoveFailed
  InvalidStopTimeout
  InspectInvalid
  InspectMismatch
  Internal
}

///|
pub fn DockerErrorCode::label(self : DockerErrorCode) -> String {
  match self {
    DockerMissing => "docker_missing"
    DockerProbeTimeout => "docker_probe_timeout"
    DockerUnavailable => "docker_unavailable"
    DockerInfoInvalid => "docker_info_invalid"
    DockerVersionUnsupported => "docker_version_unsupported"
    DockerFlagUnsupported => "docker_flag_unsupported"
    InvalidEnvironmentId => "invalid_environment_id"
    InvalidPrimaryId => "invalid_primary_id"
    InvalidWorkspaceId => "invalid_workspace_id"
    InvalidRecipeHash => "invalid_recipe_hash"
    InvalidRoot => "invalid_root"
    ForbiddenRoot => "forbidden_root"
    RootsOverlap => "roots_overlap"
    InvalidContainerPath => "invalid_container_path"
    InvalidEnvName => "invalid_env_name"
    EnvNameNotAllowed => "env_name_not_allowed"
    EnvNameDuplicate => "env_name_duplicate"
    EnvValueInvalid => "env_value_invalid"
    EnvFileInvalid => "env_file_invalid"
    EnvFileInsecure => "env_file_insecure"
    EnvFileWriteFailed => "env_file_write_failed"
    EnvFileRemoveFailed => "env_file_remove_failed"
    InvalidStopTimeout => "invalid_stop_timeout"
    InspectInvalid => "inspect_invalid"
    InspectMismatch => "inspect_mismatch"
    Internal => "internal"
  }
}

///|
pub(all) struct DockerError {
  code : DockerErrorCode
  field : String?
  detail : String?
}

///|
pub fn DockerError::new(code : DockerErrorCode) -> DockerError {
  { code, field: None, detail: None, }
}

///|
pub fn DockerError::at(self : DockerError, field : String) -> DockerError {
  { ..self, field: Some(field) }
}

///|
pub fn DockerError::with_detail(
  self : DockerError,
  detail : String,
) -> DockerError {
  { ..self, detail: Some(bounded_docker_detail(detail)), }
}

///|
pub fn DockerError::reason(self : DockerError) -> String {
  self.code.label()
}

///|
pub fn DockerError::to_string(self : DockerError) -> String {
  let mut text = self.code.label()
  match self.field {
    Some(field) if field != "" => text = text + " (" + field + ")"
    _ => ()
  }
  match self.detail {
    Some(detail) if detail != "" => text = text + ": " + detail
    _ => ()
  }
  text
}

///|
fn bounded_docker_detail(detail : String) -> String {
  let cap = 240
  if detail.length() <= cap {
    return detail
  }
  detail[:cap].to_owned() + "…"
}
