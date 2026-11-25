///|
/// Injectable node outbox port.
///
/// The transport does not implement exec/fs/PTY/git or the durable outbox;
/// A1.1a (`monexus/runtime` `Outbox`) owns event storage. This port is the
/// exact seam A1.2b must adapt:
///
/// - `pending(after_cursor, limit)` returns outbox events with
///   `seq > after_cursor`, oldest first, at most `limit`. A1.2b maps
///   `Outbox::pending_events(limit)` and filters by `after_cursor`, or exposes
///   the cursor directly.
/// - `ack_through(cursor)` maps to `Outbox::ack_through(cursor)`; the cursor is
///   the primary's acknowledged maximum outbox global `seq`.
/// - `cursor()` maps to `Outbox::cursor()` and must return the node's durable
///   ack cursor, so a reconnected node resumes exactly where it stopped.
///
/// `OutboxEvent` mirrors A1.1a `StoredEvent` field-for-field except that it is
/// defined here to keep the transport package free of a dependency cycle.

///|
pub(all) struct OutboxEvent {
  seq : Int64
  run_id : String
  run_seq : Int64
  kind : String
  ts : String
  payload : @json.Json
}

///|
pub struct OutboxPort {
  pending : async (Int64, Int) -> Result[Array[OutboxEvent], String]
  ack_through : async (Int64) -> Result[Unit, String]
  cursor : () -> Int64
}

///|
pub fn OutboxPort::new(
  pending~ : async (Int64, Int) -> Result[Array[OutboxEvent], String],
  ack_through~ : async (Int64) -> Result[Unit, String],
  cursor~ : () -> Int64,
) -> OutboxPort {
  { pending, ack_through, cursor }
}

///|
/// A port with nothing to publish. Useful for pairing-only nodes and tests.
pub fn OutboxPort::empty() -> OutboxPort {
  {
    pending: (_after, _limit) => Ok([]),
    ack_through: (_cursor) => Ok(()),
    cursor: () => 0L,
  }
}

///|
pub fn OutboxEvent::to_wire(self : OutboxEvent) -> WireEvent {
  {
    seq: self.seq,
    run_id: self.run_id,
    run_seq: self.run_seq,
    kind: self.kind,
    ts: self.ts,
    payload: self.payload,
    hash: "",
  }
}
