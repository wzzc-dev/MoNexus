///|
/// Primary → node credential control seam (A5.2).
///
/// A remote binding is metadata on the primary: the node owns the secret in
/// its own platform store. The only values that cross this seam are the
/// binding tuple, version, fingerprint and lease window. `lease` renews the
/// node's validity window and refreshes the primary's mirror; `revoke` asks
/// the node to destroy its local copy. Neither call carries secret material,
/// and the port is attached by the runtime transport layer, not by the
/// credential store.
pub(all) struct RemoteCredentialSignal {
  binding_id : String
  credential_id : String
  machine_id : String
  agent_id : String
  profile : String
  version : Int32
  fingerprint : String
  lease_ttl_ms : Int64
}

///|
pub fn RemoteCredentialSignal::new(
  binding_id~ : String,
  credential_id~ : String,
  machine_id~ : String,
  agent_id~ : String,
  profile~ : String,
  version~ : Int32,
  fingerprint~ : String,
  lease_ttl_ms~ : Int64 = 0L,
) -> RemoteCredentialSignal {
  {
    binding_id,
    credential_id,
    machine_id,
    agent_id,
    profile,
    version,
    fingerprint,
    lease_ttl_ms,
  }
}

///|
/// One metadata/control signal. `lease` is idempotent for a given binding and
/// window; `revoke` must be safe to repeat. Both return a secret-free error
/// string, which the primary records as `credential_delivery_failed` when the
/// call cannot be delivered.
pub(all) struct RemoteCredentialPort {
  lease : async (RemoteCredentialSignal) -> Result[Unit, String]
  revoke : async (RemoteCredentialSignal) -> Result[Unit, String]
}

///|
pub fn RemoteCredentialPort::new(
  lease~ : async (RemoteCredentialSignal) -> Result[Unit, String],
  revoke~ : async (RemoteCredentialSignal) -> Result[Unit, String],
) -> RemoteCredentialPort {
  { lease, revoke, }
}
