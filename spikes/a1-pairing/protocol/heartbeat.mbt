///|
/// Heartbeat accounting.
///
/// Heartbeats are JSON-RPC requests carrying a monotonic `seq`; the reply
/// acknowledges the highest contiguous sequence the primary has seen. A
/// duplicate or out-of-order `seq` is idempotent: it never regresses the ack
/// and never opens a second session.

///|
pub(all) struct HeartbeatAck {
  session_id : String
  ack_seq : Int64
  server_time_ms : Int64
  duplicate : Bool
}

///|
fn PrimaryState::session_is_live(
  self : PrimaryState,
  session : Session,
  now_ms : Int64,
) -> Bool {
  if session.closed {
    return false
  }
  match self.enrollments.get(session.runtime_id) {
    Some(enrollment) =>
      !enrollment.revoked &&
      enrollment.expires_at_ms > now_ms &&
      enrollment.credential_id == session.credential_id
    None => false
  }
}

///|
pub fn PrimaryState::heartbeat(
  self : PrimaryState,
  session_id : String,
  seq : Int64,
  now_ms : Int64,
) -> Result[HeartbeatAck, String] {
  let session = match self.sessions.get(session_id) {
    Some(value) => value
    None => return Err("unknown session")
  }
  if !self.session_is_live(session, now_ms) {
    session.closed = true
    self.log_line(
      "heartbeat rejected session_id=\{session_id} reason=session_closed",
    )
    return Err("unauthorized")
  }
  if !self.has_scope(session.runtime_id, "runtime.heartbeat") {
    return Err("forbidden")
  }
  if seq <= session.last_ack_seq {
    self.log_line(
      "heartbeat duplicate session_id=\{session_id} seq=\{seq} ack=\{session.last_ack_seq}",
    )
    return Ok({
      session_id,
      ack_seq: session.last_ack_seq,
      server_time_ms: now_ms,
      duplicate: true,
    })
  }
  session.last_ack_seq = seq
  session.last_heartbeat_ms = now_ms
  self.last_ack.set(session.runtime_id, seq)
  self.log_line("heartbeat session_id=\{session_id} seq=\{seq}")
  Ok({
    session_id,
    ack_seq: seq,
    server_time_ms: now_ms,
    duplicate: false,
  })
}

///|
/// True when the session has missed more than `HEARTBEAT_MAX_MISSED`
/// intervals. The spike keeps this as a pure predicate; A1.2 will react by
/// marking the session `lost` and reconciling unfinished runs.
pub fn session_is_stale(session : Session, now_ms : Int64) -> Bool {
  now_ms - session.last_heartbeat_ms >
  HEARTBEAT_INTERVAL_MS * HEARTBEAT_MAX_MISSED.to_int64()
}
