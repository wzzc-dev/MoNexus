///|
/// A structured runtime error for the transport-facing APIs added by the
/// PTY/git integration (A1.1b integration slice).
///
/// `code` reuses the JSON-RPC error codes from `@contracts.rpc` so A1.2b can
/// place it in a `RpcError` without a second mapping table:
///
/// | condition                                    | code               |
/// |----------------------------------------------|--------------------|
/// | caller-fixable input, unknown resource,      | ERR_INVALID_PARAMS |
/// | path outside the root                        |                    |
/// | git not enabled                              | ERR_INVALID_REQUEST |
/// | state-dependent failure (conflict, timeout,  | ERR_HOST           |
/// | spawn, git exit, not a repository)           |                    |
/// | internal I/O, outbox, state-dir failure      | ERR_INTERNAL       |
///
/// `kind` is the stable machine-readable reason (`invalid_argument`,
/// `not_found`, `path_denied`, `conflict`, `not_enabled`, `already_closed`,
/// `spawn_failed`, `io`, `timeout`, `state_dir`, `not_git`, `exit`,
/// `session_lost`, `outbox_error`, `internal`). The message is bounded and
/// redacted; it never carries env values, argv secrets or key material.
pub(all) struct RuntimeError {
  code : Int
  kind : String
  message : String
  run_seq : Int64
}

///|
pub fn runtime_error(
  code : Int,
  kind : String,
  message : String,
) -> RuntimeError {
  { code, kind, message, run_seq: -1L, }
}

///|
fn RuntimeError::with_run_seq(self : RuntimeError, run_seq : Int64) -> RuntimeError {
  { ..self, run_seq, }
}

///|
pub fn RuntimeError::to_json(self : RuntimeError) -> @json.Json {
  @contracts.json_object([
    ("code", @contracts.json_int(self.code)),
    ("kind", @contracts.json_string(self.kind)),
    ("message", @contracts.json_string(self.message)),
    ("run_seq", @contracts.json_int64(self.run_seq)),
  ])
}

///|
fn runtime_invalid(kind : String, message : String) -> RuntimeError {
  runtime_error(@contracts.ERR_INVALID_PARAMS, kind, bounded_runtime_message(message))
}

///|
fn runtime_host(kind : String, message : String) -> RuntimeError {
  runtime_error(@contracts.ERR_HOST, kind, bounded_runtime_message(message))
}

///|
fn runtime_internal(kind : String, message : String) -> RuntimeError {
  runtime_error(@contracts.ERR_INTERNAL, kind, bounded_runtime_message(message))
}

///|
fn runtime_not_enabled() -> RuntimeError {
  runtime_error(
    @contracts.ERR_INVALID_REQUEST,
    "not_enabled",
    "git is not enabled for this runtime; call open_git first",
  )
}

///|
/// Redact and bound a caller-visible error message. Kept short so an error
/// event payload stays small and cannot carry a credential.
fn bounded_runtime_message(text : String) -> String {
  let redacted = @contracts.redact_secrets(text)
  if redacted.length() <= 512 {
    redacted
  } else {
    redacted[:512].to_string() + "...[truncated]"
  }
}
