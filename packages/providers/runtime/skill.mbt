///|
/// Primary-side mirrored skill calls (ADR-0015 A4.2).
///
/// The primary verifies and allowlists the bundle; it sends the exact
/// manifest and files to the node, which re-derives the content hash before
/// storing them. Invocation goes through the same Decision/approval handshake
/// as `exec.start`: the node returns a binding, the owner answers an existing
/// Decision, and the grant-bound resend executes exactly once. Nothing here
/// approves or executes locally.

///|
pub async fn RuntimeMachine::skill_mirror(
  self : RuntimeMachine,
  session_id~ : String,
  name~ : String,
  version~ : String,
  content_hash~ : String,
  manifest~ : String,
  files~ : Array[(String, String)],
  lease_ms~ : Int64 = 3_600_000L,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let file_entries : Array[@json.Json] = []
  for file in files {
    file_entries.push(
      @contracts.json_object([
        ("path", @contracts.json_string(file.0)),
        ("content", @contracts.json_string(file.1)),
      ]),
    )
  }
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("name", @contracts.json_string(name))
  params.set("version", @contracts.json_string(version))
  params.set("content_hash", @contracts.json_string(content_hash))
  params.set("manifest", @contracts.json_string(manifest))
  params.set("files", @contracts.json_array(file_entries))
  params.set("lease_ms", @contracts.json_int64(lease_ms))
  self.request_with_id(
    @contracts.METHOD_RUNTIME_SKILL_MIRROR,
    params,
    client_request_id,
  )
}

///|
pub async fn RuntimeMachine::skill_list(
  self : RuntimeMachine,
  session_id~ : String = "",
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  if session_id != "" {
    params.set("session_id", @contracts.json_string(session_id))
  }
  self.request(@contracts.METHOD_RUNTIME_SKILL_LIST, params)
}

///|
pub async fn RuntimeMachine::skill_gc(
  self : RuntimeMachine,
  session_id~ : String = "",
  force~ : Bool = false,
  client_request_id~ : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let params : Map[String, @json.Json] = Map([])
  if session_id != "" {
    params.set("session_id", @contracts.json_string(session_id))
  }
  if force {
    params.set("force", @contracts.json_bool(true))
  }
  self.request_with_id(
    @contracts.METHOD_RUNTIME_SKILL_GC,
    params,
    client_request_id,
  )
}

///|
/// Invoke one mirrored entry with Decision-bound approval. The node chooses
/// the argv from its verified mirror; the primary supplies only the exact
/// tuple and entry id. The run id binds the Decision, the digest and the
/// one-shot grant.
pub async fn RuntimeMachine::skill_invoke_approved(
  self : RuntimeMachine,
  session_id~ : String,
  name~ : String,
  version~ : String,
  content_hash~ : String,
  entry_id~ : String,
  run_id~ : String,
  client_request_id~ : String,
  cwd~ : String = "",
  approval~ : ApprovalContext,
) -> Result[@json.Json, ApprovalFailure] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("name", @contracts.json_string(name))
  params.set("version", @contracts.json_string(version))
  params.set("content_hash", @contracts.json_string(content_hash))
  params.set("entry_id", @contracts.json_string(entry_id))
  params.set("run_id", @contracts.json_string(run_id))
  if cwd != "" {
    params.set("cwd", @contracts.json_string(cwd))
  }
  self.mutate_with_approval(
    rpc_method=@contracts.METHOD_RUNTIME_SKILL_INVOKE,
    params~,
    binding_run_id=run_id,
    client_request_id~,
    command=["skill.invoke", name + "@" + version, entry_id],
    approval~,
  )
}
