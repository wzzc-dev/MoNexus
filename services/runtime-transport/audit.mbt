///|
/// Bounded audit and diagnostic rings for the primary.
///
/// Audit entries and log lines are redacted with `@contracts.redact_secrets`
/// and length-clamped before they enter the ring. Callers never pass pairing
/// codes or bearer tokens here; the rings additionally scrub secret-shaped
/// text as defence in depth, and the tests assert that no issued secret appears
/// in either ring.

///|
pub struct AuditLog {
  events : Array[@json.Json]
  lines : Array[String]
}

///|
pub fn AuditLog::new() -> AuditLog {
  { events: [], lines: [] }
}

///|
fn ring_push_json(ring : Array[@json.Json], value : @json.Json) -> Unit {
  ring.push(value)
  if ring.length() > MAX_AUDIT_EVENTS {
    let _ = ring.remove(0)
  }
}

///|
fn ring_push_line(ring : Array[String], value : String) -> Unit {
  ring.push(value)
  if ring.length() > MAX_LOG_LINES {
    let _ = ring.remove(0)
  }
}

///|
/// Append one audit entry. `detail` is redacted and clamped; `outcome` is a
/// short machine label such as `ok`, `rejected` or `rate_limited`.
pub fn AuditLog::record(
  self : AuditLog,
  action : String,
  subject : String,
  outcome : String,
  detail : String,
  now_ms : Int64,
) -> Unit {
  ring_push_json(
    self.events,
    @contracts.json_object([
      ("action", @contracts.json_string(action)),
      ("subject", @contracts.json_string(clamp_text(subject, MAX_RUNTIME_ID_LEN))),
      ("outcome", @contracts.json_string(clamp_text(outcome, 64))),
      ("detail", @contracts.json_string(safe_detail(detail))),
      ("ts_ms", @contracts.json_int64(now_ms)),
    ]),
  )
}

///|
/// Append one diagnostic line. Always redacted and bounded.
pub fn AuditLog::log_line(self : AuditLog, line : String) -> Unit {
  ring_push_line(self.lines, safe_detail(line))
}

///|
pub fn AuditLog::events(self : AuditLog) -> Array[@json.Json] {
  self.events
}

///|
pub fn AuditLog::lines(self : AuditLog) -> Array[String] {
  self.lines
}

///|
/// Flattened audit text for tests and diagnostics.
pub fn AuditLog::text(self : AuditLog) -> String {
  let parts : Array[String] = []
  for event in self.events {
    parts.push(event.stringify())
  }
  for line in self.lines {
    parts.push(line)
  }
  parts.join("\n")
}
