///|
/// Runtime node host (A1.2b).
///
/// One node serves exactly one runtime id. It owns:
///
/// - a 0700 state directory `$MONEXUS_RUNTIME_DIR/<runtime_id>` (default
///   `~/.monexus/runtime/<runtime_id>`), containing the identity document,
///   the 0600 bearer token and the runtime core's state root;
/// - the runtime execution core (`monexus/runtime`), opened before serving so
///   interrupted runs are durably finalized as `lost`;
/// - a rooted workspace (the runtime work dir, or an explicit `--workspace`);
/// - the policy gate and the bounded idempotency cache.
///
/// Pairing and the session loop belong to the transport (`monexus/runtime-
/// transport`): `pair` exchanges the one-time code for a credential saved
/// 0600; `serve` runs `node_serve` on the pinned TLS connection and answers
/// `runtime.probe` natively plus every `runtime.exec|fs|pty|git.*` method via
/// the registered handlers.

///|
pub const NODE_STATE_VERSION : Int = 1

///|
pub const NODE_HEARTBEAT_INTERVAL_MS : Int64 = 10_000L

///|
pub const NODE_TOKEN_FILE_NAME : String = "token"

///|
pub const NODE_IDENTITY_FILE_NAME : String = "identity.json"

///|
/// Persisted policy announcement. The file lives in the node's 0700 state
/// directory, is written 0600 and contains only the public snapshot and its
/// content hash. It is re-verified on every open; a tampered file is ignored
/// and the gate stays fail-closed (or operator-overridden).
pub const NODE_POLICY_FILE_NAME : String = "policy.json"

///|
pub fn node_capabilities() -> Array[String] {
  ["exec", "fs", "pty", "git"]
}

///|
pub fn node_default_state_base() -> String {
  match @env.get_env_var("MONEXUS_RUNTIME_DIR") {
    Some(value) if value != "" => return value
    _ => ()
  }
  match @env.get_env_var("HOME") {
    Some(home) if home != "" => home + "/.monexus/runtime"
    _ => ".monexus/runtime"
  }
}

///|
/// A running node's owned state. Open once at startup; it is not safe to open
/// the same runtime id twice against the same state directory.
pub struct NodeHost {
  runtime_id : String
  state_dir : String
  identity_path : String
  token_path : String
  executor : @runtime.RuntimeExecutor
  workspace : @runtime.RootedDir
  workspace_root : String
  mut policy : PolicyGate
  cache : IdempotencyCache
  /// Bounded replay memory for consumed approval grant nonces. This is the
  /// only approval-related state the node keeps: it does not hold Decisions,
  /// pending approvals or grants, and cannot approve anything itself.
  nonces : @policy.ConsumedNonces
  /// Node-local bounded audit ring for policy decisions and snapshot
  /// installation. The primary remains the system of record.
  audit : @transport.AuditLog
}

///|
pub fn NodeHost::runtime_id(self : NodeHost) -> String {
  self.runtime_id
}

///|
pub fn NodeHost::state_dir(self : NodeHost) -> String {
  self.state_dir
}

///|
pub fn NodeHost::token_path(self : NodeHost) -> String {
  self.token_path
}

///|
pub fn NodeHost::workspace_root(self : NodeHost) -> String {
  self.workspace_root
}

///|
pub fn NodeHost::policy(self : NodeHost) -> PolicyGate {
  self.policy
}

///|
/// Replace the policy gate (A1.3b snapshot injection). The caller decides
/// whether the snapshot is trustworthy; a malformed snapshot must be rejected
/// before this call, leaving the previous gate in place.
pub fn NodeHost::set_policy(self : NodeHost, policy : PolicyGate) -> Unit {
  self.policy = policy
}

///|
pub fn NodeHost::policy_path(self : NodeHost) -> String {
  self.state_dir + "/" + NODE_POLICY_FILE_NAME
}

///|
/// Node-local audit text (redacted, bounded). Used by tests and doctor output.
pub fn NodeHost::audit_text(self : NodeHost) -> String {
  self.audit.text()
}

///|
fn node_audit(
  host : NodeHost,
  action : String,
  outcome : String,
  detail : String,
) -> Unit {
  host.audit.record(
    action,
    host.runtime_id,
    outcome,
    detail,
    @async.now(),
  )
}

///|
/// Install a policy announcement pushed by the primary. The pinned hash is
/// re-verified here; only a valid snapshot replaces the gate. The announcement
/// is persisted 0600 in the node state directory so a restart resumes under
/// the same policy, and re-verified when it is loaded again.
pub async fn NodeHost::install_policy_announcement(
  self : NodeHost,
  announcement : @transport.PolicyAnnouncement,
) -> Result[Unit, String] {
  let snapshot = match announcement.verify() {
    Ok(value) => value
    Err(message) => {
      node_audit(
        self,
        "policy.snapshot_rejected",
        "rejected",
        "source=primary version=" +
        announcement.version +
        " reason=" +
        message,
      )
      return Err(message)
    }
  }
  let text = announcement.to_json().stringify()
  match
    @transport.save_policy_announcement(self.policy_path(), text) {
    Ok(_) => ()
    Err(message) => {
      node_audit(
        self,
        "policy.snapshot_rejected",
        "rejected",
        "source=primary version=" +
        announcement.version +
        " reason=" +
        message,
      )
      return Err(message)
    }
  }
  self.policy = PolicyGate::from_policy_snapshot(snapshot)
  node_audit(
    self,
    "policy.snapshot_installed",
    "ok",
    "source=primary version=" +
    snapshot.version +
    " hash=" +
    snapshot.content_hash,
  )
  Ok(())
}

///|
async fn ensure_state_dir(path : String) -> Result[Unit, String] {
  @fs.mkdir(path, permission=0o700, recursive=true, allow_exist=true) catch {
    error => return Err("cannot create runtime state dir: " + error.to_string())
  }
  @transport.validate_private_dir(path, "runtime state dir")
}

///|
async fn read_identity(
  path : String,
  runtime_id : String,
) -> Result[Unit, String] {
  let text = @fs.read_file(path).text() catch {
    error => return Err("cannot read runtime identity: " + error.to_string())
  }
  let parsed = @json.parse(text) catch {
    _ => return Err("runtime identity is not valid JSON")
  }
  let object = match @contracts.as_object(parsed) {
    Some(value) => value
    None => return Err("runtime identity is not an object")
  }
  let stored_id = @contracts.string_field_or(object, "runtime_id", "")
  if stored_id != runtime_id {
    return Err(
      "runtime identity belongs to a different runtime id: " + stored_id,
    )
  }
  let version = @contracts.int_field_or(object, "version", 0)
  if version != NODE_STATE_VERSION {
    return Err(
      "unsupported runtime identity version: " + version.to_string(),
    )
  }
  @transport.validate_secret_file(path, "runtime identity file")
}

///|
async fn create_identity(
  path : String,
  runtime_id : String,
  created_at : String,
) -> Result[Unit, String] {
  let document = @contracts.json_object([
    ("runtime_id", @contracts.json_string(runtime_id)),
    ("version", @contracts.json_int(NODE_STATE_VERSION)),
    ("created_at", @contracts.json_string(created_at)),
  ])
  @fs.write_file(
    path,
    document.stringify(),
    create_mode=@fs.CreateMode::CreateNew,
    permission=0o600,
    sync=@fs.SyncMode::Data,
  ) catch {
    error => return Err("cannot write runtime identity: " + error.to_string())
  }
  @transport.validate_secret_file(path, "runtime identity file")
}

///|
/// Open (or create) the node state for `runtime_id`.
///
/// `state_base` defaults to `$MONEXUS_RUNTIME_DIR` or
/// `~/.monexus/runtime`; the identity and token live in
/// `<state_base>/<runtime_id>/`. `workspace_root` defaults to the runtime
/// core's own work directory, which is created 0700 on first open.
pub async fn NodeHost::open(
  runtime_id : String,
  state_base~ : String = "",
  workspace_root~ : String = "",
  policy~ : PolicyGate? = None,
  pty_limits~ : @pty_runtime.PtyLimits? = None,
  git_limits~ : @git_runtime.GitLimits? = None,
) -> Result[NodeHost, String] {
  if !@transport.is_safe_id(runtime_id) {
    return Err("invalid runtime id")
  }
  let base = if state_base == "" {
    node_default_state_base()
  } else {
    state_base
  }
  match ensure_state_dir(base) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let state_dir = base + "/" + runtime_id
  match ensure_state_dir(state_dir) {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  let identity_path = state_dir + "/" + NODE_IDENTITY_FILE_NAME
  let exists = @fs.exists(identity_path) catch { _ => false }
  if exists {
    match read_identity(identity_path, runtime_id) {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  } else {
    match create_identity(identity_path, runtime_id, @contracts.format_rfc3339(@async.now())) {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  let executor = match (pty_limits, git_limits) {
    (None, None) => @runtime.RuntimeExecutor::open(state_dir, runtime_id)
    (pty, git) => {
      let pty_limits = match pty {
        Some(value) => value
        None => @pty_runtime.PtyLimits::new()
      }
      let git_limits = match git {
        Some(value) => value
        None => @git_runtime.GitLimits::new()
      }
      @runtime.RuntimeExecutor::open_with_limits(
        state_dir,
        runtime_id,
        pty_limits~,
        git_limits~,
      )
    }
  }
  let executor = match executor {
    Ok(value) => value
    Err(message) => return Err("cannot open runtime executor: " + message)
  }
  let requested = if workspace_root.trim() == "" {
    executor.state_root() + "/work"
  } else {
    workspace_root.trim().to_owned()
  }
  let workspace = match @runtime.RootedDir::open(requested) {
    Ok(value) => value
    Err(message) => {
      executor.close()
      return Err("cannot open runtime workspace: " + message)
    }
  }
  // Restore the last policy snapshot the primary published. The file is
  // re-verified against its pinned hash; a missing or tampered file leaves the
  // node fail-closed until the next successful install.
  let audit = @transport.AuditLog::new()
  let policy_path = state_dir + "/" + NODE_POLICY_FILE_NAME
  let policy_file_exists = @fs.exists(policy_path) catch { _ => false }
  let restored : @policy.PolicySnapshot? = if policy_file_exists {
    match @transport.load_policy_announcement(policy_path) {
      Ok(announcement) =>
        match announcement.verify() {
          Ok(snapshot) => {
            audit.record(
              "policy.snapshot_restored",
              runtime_id,
              "ok",
              "source=disk version=" +
              snapshot.version +
              " hash=" +
              snapshot.content_hash,
              @async.now(),
            )
            Some(snapshot)
          }
          Err(message) => {
            audit.record(
              "policy.snapshot_rejected",
              runtime_id,
              "rejected",
              "source=disk reason=" + message,
              @async.now(),
            )
            None
          }
        }
      Err(message) => {
        audit.record(
          "policy.snapshot_rejected",
          runtime_id,
          "rejected",
          "source=disk reason=" + message,
          @async.now(),
        )
        None
      }
    }
  } else {
    None
  }
  // An explicit policy argument (operator override or a test gate) wins over
  // the restored file; otherwise the persisted primary snapshot is used.
  let effective_policy = match policy {
    Some(value) => value
    None =>
      match restored {
        Some(snapshot) => PolicyGate::from_policy_snapshot(snapshot)
        None => PolicyGate::fail_closed()
      }
  }
  Ok({
    runtime_id,
    state_dir,
    identity_path,
    token_path: state_dir + "/" + NODE_TOKEN_FILE_NAME,
    executor,
    workspace,
    workspace_root: workspace.root(),
    policy: effective_policy,
    cache: IdempotencyCache::new(),
    nonces: @policy.ConsumedNonces::new(),
    audit,
  })
}

///|
/// Pair with a primary using a one-time code. The credential is written 0600
/// to the node's token file by the transport; it is never printed or logged.
pub async fn NodeHost::pair(
  self : NodeHost,
  config : @transport.NodeConfig,
  pairing_code : String,
) -> Result[@transport.PairGrant, String] {
  let effective = {
    ..config,
    runtime_id: self.runtime_id,
    capabilities: if config.capabilities.is_empty() {
      node_capabilities()
    } else {
      config.capabilities
    },
    token_file: Some(self.token_path),
  }
  match @transport.pair_with_primary(effective, pairing_code) {
    Ok(grant) => {
      if grant.runtime_id != self.runtime_id {
        return Err("primary paired a different runtime id")
      }
      Ok(grant)
    }
    Err(error) => Err(node_connect_error_text(error))
  }
}

///|
pub async fn NodeHost::load_token(self : NodeHost) -> Result[String, String] {
  @transport.load_token_file(self.token_path)
}

///|
pub fn node_connect_error_text(error : @transport.NodeConnectError) -> String {
  match error {
    @transport.NodeRevoked => "runtime is revoked"
    @transport.NodeUnauthorized => "runtime is unauthorized"
    @transport.NodeUnsupportedVersion => "unsupported protocol version"
    @transport.NodeTransport(message) => "transport error: " + message
    @transport.NodeProtocol(message) => "protocol error: " + message
  }
}

///|
fn bounded_platform_text(text : String) -> String {
  let trimmed = text.trim()
  if trimmed.length() > 128 {
    trimmed[:128].to_owned()
  } else {
    trimmed.to_owned()
  }
}

///|
async fn platform_facts() -> (String, String, String) {
  let script = "uname -s; uname -m; uname -n"
  let text = match @async.with_timeout_opt(5_000, async fn() {
    let (_, stdout, _) = @process.collect_output("/bin/sh", ["-c", script]) catch {
      _ => return ""
    }
    stdout.text() catch { _ => "" }
  }) {
    Some(value) => value
    None => ""
  }
  let lines : Array[String] = []
  for piece in text.split("\n") {
    let line = piece.to_owned().trim().to_owned()
    if line != "" {
      lines.push(line)
    }
  }
  let os = if lines.length() > 0 { bounded_platform_text(lines[0]) } else { "" }
  let arch = if lines.length() > 1 { bounded_platform_text(lines[1]) } else { "" }
  let hostname = if lines.length() > 2 { bounded_platform_text(lines[2]) } else { "" }
  (os, arch, hostname)
}

///|
/// The profile answered by `runtime.probe`. It is collected over the runtime
/// host's own API (no ACP connection, no shell interpolation of user text).
pub async fn NodeHost::probe_profile(self : NodeHost) -> @json.Json {
  let (os, arch, hostname) = platform_facts()
  let policy_text = self.policy.mode()
  let (policy_version, policy_hash) = match
    self.policy.verified_snapshot() {
    Some(snapshot) => (snapshot.version, snapshot.content_hash)
    None => ("", "")
  }
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(self.runtime_id)),
    (
      "transport_version",
      @contracts.json_string(@transport.PROTOCOL_VERSION_TEXT),
    ),
    ("protocol_version", @contracts.json_int(@transport.PROTOCOL_VERSION)),
    ("capabilities", @contracts.json_string_array(node_capabilities())),
    (
      "workspace_roots",
      @contracts.json_string_array([self.workspace_root]),
    ),
    (
      "platform",
      @contracts.json_object([
        ("os", @contracts.json_string(os)),
        ("arch", @contracts.json_string(arch)),
        ("hostname", @contracts.json_string(hostname)),
      ]),
    ),
    ("policy", @contracts.json_string(policy_text)),
    ("policy_version", @contracts.json_string(policy_version)),
    ("policy_hash", @contracts.json_string(policy_hash)),
    ("state_version", @contracts.json_int(NODE_STATE_VERSION)),
  ])
}

///|
fn NodeHost::outbox_port(self : NodeHost) -> @transport.OutboxPort {
  let executor = self.executor
  @transport.OutboxPort::new(
    pending=async fn(after_cursor : Int64, limit : Int) {
      let events = match executor.pending_events(limit) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
      let out : Array[@transport.OutboxEvent] = []
      for event in events {
        if event.seq > after_cursor && out.length() < limit {
          out.push({
            seq: event.seq,
            run_id: event.run_id,
            // The transport wire contract requires a positive per-run seq,
            // while the runtime core numbers each stream from 0. The shift is
            // applied once here, at the transport boundary, so dedupe stays
            // `(runtime_id, run_id, run_seq)` for every consumer.
            run_seq: event.run_seq + 1L,
            kind: event.kind,
            ts: event.ts,
            payload: event.payload,
          })
        }
      }
      Ok(out)
    },
    ack_through=async fn(cursor : Int64) {
      executor.ack_through(cursor)
    },
    cursor=fn() {
      executor.cursor()
    },
  )
}

///|
/// Build the transport service for one serving task group. The registered
/// handlers dispatch to the runtime core; `group` must outlive the runs it
/// spawns (it does: it is the group around `node_serve`, which spans
/// reconnects).
pub fn NodeHost::service(
  self : NodeHost,
  group : @async.TaskGroup[Unit],
) -> @transport.NodeService {
  let handlers = @transport.HandlerRegistry::new()
  for rpc_method in @contracts.runtime_application_methods() {
    let _ = handlers.register(rpc_method, async fn(request) {
      self.dispatch(request, group)
    })
  }
  let probe : async () -> @json.Json = async fn() {
    self.probe_profile()
  }
  let outbox = self.outbox_port()
  let install_policy : async (@transport.PolicyAnnouncement) -> Result[Unit, String] =
    async fn(announcement) {
      self.install_policy_announcement(announcement)
    }
  @transport.NodeService::new(handlers~, probe~, outbox~, install_policy~)
}

///|
/// Serve the paired session until drain, revocation or an exhausted attempt
/// budget. Runs `exec.start` and PTY processes inside the serving group, so a
/// reconnect keeps them alive and their events are published from the durable
/// outbox once the channel is back.
pub async fn NodeHost::serve(
  self : NodeHost,
  config : @transport.NodeConfig,
) -> @transport.NodeRunOutcome {
  let token = match self.load_token() {
    Ok(value) => value
    Err(message) => return @transport.NodeRunOutcome::Stopped(message)
  }
  let effective = {
    ..config,
    runtime_id: self.runtime_id,
    capabilities: if config.capabilities.is_empty() {
      node_capabilities()
    } else {
      config.capabilities
    },
    token_file: Some(self.token_path),
  }
  let outcome : Ref[@transport.NodeRunOutcome] = Ref(
    @transport.NodeRunOutcome::Stopped("node serve did not start"),
  )
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let service = self.service(group)
    outcome.val = @transport.node_serve(effective, token, service, group)
  })
  outcome.val
}
