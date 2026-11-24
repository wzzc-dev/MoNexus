///|
/// Provider error categories (architecture §6.2, ADR 0003). Keeping the
/// categories explicit prevents M2 from confusing `ssh` exit code 255
/// (authentication/connection) with a remote command's real exit code.
pub(all) enum ProviderErrorKind {
  AuthFailed
  ConnectTimeout
  Transport
  RemoteExit
  NotConfigured
  SpawnFailed
  PtyFailed
  Cancelled
  Internal
}

///|
pub fn ProviderErrorKind::label(self : ProviderErrorKind) -> String {
  match self {
    AuthFailed => "auth_failed"
    ConnectTimeout => "connect_timeout"
    Transport => "transport"
    RemoteExit => "remote_exit"
    NotConfigured => "not_configured"
    SpawnFailed => "spawn_failed"
    PtyFailed => "pty_failed"
    Cancelled => "cancelled"
    Internal => "internal"
  }
}

///|
pub(all) struct ProviderError {
  kind : ProviderErrorKind
  message : String
  exit_code : Int?
  detail : String?
}

///|
pub fn ProviderError::new(
  kind : ProviderErrorKind,
  message : String,
) -> ProviderError {
  { kind, message, exit_code: None, detail: None, }
}

///|
pub fn ProviderError::with_exit(
  self : ProviderError,
  exit_code : Int,
) -> ProviderError {
  { ..self, exit_code: Some(exit_code) }
}

///|
pub fn ProviderError::with_detail(
  self : ProviderError,
  detail : String,
) -> ProviderError {
  { ..self, detail: Some(detail) }
}

///|
pub fn ProviderError::to_string(self : ProviderError) -> String {
  let mut text = self.kind.label() + ": " + self.message
  match self.exit_code {
    Some(code) => text = text + " (exit " + code.to_string() + ")"
    None => ()
  }
  match self.detail {
    Some(detail) if detail != "" => text = text + ": " + detail
    _ => ()
  }
  text
}
