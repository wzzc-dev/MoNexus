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
/// - a rooted workspace: the runtime core's work dir. An explicit
///   `--workspace` must resolve to that same real root, because exec children,
///   fs, PTY and git all run there and the policy digest binds that path;
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
/// Durable replay memory for consumed approval-grant nonces. Written 0600 in
/// the 0700 state directory before an approved request executes, so a restart
/// cannot present an already-used grant again.
pub const NODE_NONCES_FILE_NAME : String = "consumed_nonces.json"

///|
/// Durable idempotency tombstones/results for one-shot mutations (fs, PTY,
/// git and control calls). Written 0600 in the 0700 state directory; a
/// `pending` entry means the request was accepted and must not run twice.
pub const NODE_IDEMPOTENCY_FILE_NAME : String = "idempotency.json"

///|
/// Bound for the consumed-nonce file. 1024 live grants encoded as
/// `[nonce,expiry]` fit comfortably; an oversized file is refused rather than
/// partially loaded, because forgetting a nonce is a replay window.
pub const MAX_NONCE_FILE_BYTES : Int64 = 262_144L

///|
/// Directory (under the node user's home) that holds environment temp
/// directories and env-file hand-offs for A2.2. The primary computes
/// `~/.monexus/environments/<environment_id>/` from the home reported by
/// `runtime.probe`; the node only ever exposes this one root over
/// `runtime.fs.*` with the `environments` selector.
pub const NODE_ENVIRONMENT_DIR_NAME : String = ".monexus/environments"

///|
/// Whether a bare program name resolves on the node's PATH. Used by the probe
/// to report whether the environment backend can run docker at all; it does
/// not start the program.
async fn program_on_path(name : String) -> Bool {
  let path_var = match @env.get_env_var("PATH") {
    Some(value) => value
    None => "/usr/local/bin:/usr/bin:/bin"
  }
  for dir in path_var.split(":") {
    let candidate = if dir == "" {
      "/" + name
    } else {
      dir.to_owned() + "/" + name
    }
    let exists = @fs.exists(candidate) catch { _ => false }
    if exists {
      let kind = @fs.kind(candidate, follow_symlink=true) catch {
        _ => @fs.FileKind::Unknown
      }
      if kind is @fs.FileKind::Regular {
        return true
      }
    }
  }
  false
}

///|
fn node_default_home() -> String {
  match @env.get_env_var("HOME") {
    Some(value) if value != "" => value
    _ => ""
  }
}

///|
pub fn node_capabilities() -> Array[String] {
  ["exec", "fs", "pty", "git", "process"]
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
  /// The node user's home directory. Reported by `runtime.probe`; the primary
  /// derives `~/.monexus/environments/<id>/` from it (A2.2).
  home : String
  /// Real path of the one additional rooted filesystem A2.2 exposes:
  /// `<home>/.monexus/environments` (0700). `None` when the node has no home,
  /// in which case environment filesystem requests fail honestly.
  environment_root : String
  environments : @runtime.RootedDir?
  executor : @runtime.RuntimeExecutor
  workspace : @runtime.RootedDir
  workspace_root : String
  mut policy : PolicyGate
  cache : IdempotencyCache
  /// Durable idempotency for mutations that have no durable run record of
  /// their own (fs, PTY, git and control calls). Loaded at open and persisted
  /// before dispatch.
  durable : DurableIdempotency
  /// Bounded replay memory for consumed approval grant nonces. This is the
  /// only approval-related state the node keeps: it does not hold Decisions,
  /// pending approvals or grants, and cannot approve anything itself. It is
  /// serialized to the 0600 nonce file before an approved request executes.
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
pub fn NodeHost::home(self : NodeHost) -> String {
  self.home
}

///|
/// Real path of the node-owned environment root
/// (`<home>/.monexus/environments`), or `""` when the node has no usable
/// home. The primary derives env directories from `probe.home`, so both
/// agree on the same absolute path.
pub fn NodeHost::environment_root(self : NodeHost) -> String {
  self.environment_root
}

///|
/// The rooted environment filesystem used by `runtime.fs.*` requests with the
/// `environments` selector.
pub fn NodeHost::environments(self : NodeHost) -> @runtime.RootedDir? {
  self.environments
}

///|
/// Release the runtime executor. The state directory (policy, nonces,
/// idempotency tombstones) stays on disk, so a later `open` for the same
/// runtime id resumes with the same replay memory.
pub fn NodeHost::close(self : NodeHost) -> Unit {
  self.executor.close()
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
async fn NodeHost::persist_consumed_nonces(self : NodeHost) -> Result[Unit, String] {
  self.nonces.prune_expired(@async.now())
  let text = self.nonces.encode()
  if text.length().to_int64() > MAX_NONCE_FILE_BYTES {
    return Err("consumed nonce file would exceed its bound")
  }
  save_node_state_file(
    self.state_dir + "/" + NODE_NONCES_FILE_NAME,
    text,
    "consumed nonce file",
  )
}

///|
/// Write a bounded node state file atomically: 0600 with full fsync inside the
/// already validated 0700 state directory.
async fn save_node_state_file(
  path : String,
  text : String,
  label : String,
) -> Result[Unit, String] {
  let dir = durable_parent_dir(path)
  if dir != "" {
    match @transport.validate_private_dir(dir, "runtime state dir") {
      Ok(_) => ()
      Err(message) => return Err(message)
    }
  }
  let temp = path + ".tmp"
  @fs.write_file(temp, text, permission=0o600, sync=@fs.SyncMode::Full) catch {
    error => return Err("cannot write " + label + ": " + error.to_string())
  }
  @fs.chmod(temp, 0o600) catch { _ => () }
  @fs.rename(temp, path, replace=true) catch {
    error => return Err("cannot replace " + label + ": " + error.to_string())
  }
  Ok(())
}

///|
/// Restore the consumed-nonce file. A missing file is an empty memory; a
/// malformed, oversized or non-0600 file fails the open rather than silently
/// forgetting nonces that could still be replayed.
async fn load_consumed_nonces(
  path : String,
  now_ms : Int64,
) -> Result[@policy.ConsumedNonces, String] {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return Ok(@policy.ConsumedNonces::new())
  }
  let stat = match @transport.lstat_path(path) {
    None => return Err("consumed nonce file is missing")
    Some(value) => value
  }
  match stat.kind {
    @transport.PathKind::Regular =>
      if (stat.mode & 0o777) != 0o600 {
        return Err(
          "consumed nonce file must be 0600 (found mode " +
          @transport.mode_text(stat.mode) + ")",
        )
      }
    _ => return Err("consumed nonce file is not a regular file")
  }
  if stat.size > MAX_NONCE_FILE_BYTES {
    return Err("consumed nonce file exceeds its bound")
  }
  let data = @fs.read_file(path) catch {
    error => return Err("cannot read consumed nonce file: " + error.to_string())
  }
  let text = data.text() catch {
    error =>
      return Err("cannot decode consumed nonce file: " + error.to_string())
  }
  let nonces = match @policy.ConsumedNonces::decode(text) {
    Ok(value) => value
    Err(message) => return Err("consumed nonce file is invalid: " + message)
  }
  nonces.prune_expired(now_ms)
  Ok(nonces)
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
  // Monotonic delivery: a valid but older announcement must not roll the node
  // back. Same version text must carry the identical pinned hash (a
  // same-version republish with different rules is a new generation and needs
  // a strictly newer version whose issued_at advances).
  match self.policy.verified_snapshot() {
    Some(installed) => {
      let rejection = if snapshot.version == installed.version {
        if snapshot.content_hash != installed.content_hash {
          Some("same policy version with a different snapshot hash")
        } else {
          None
        }
      } else if snapshot.issued_at_ms <= installed.issued_at_ms {
        Some("policy announcement is older than the installed generation")
      } else {
        None
      }
      match rejection {
        Some(reason) => {
          node_audit(
            self,
            "policy.snapshot_rejected",
            "rejected",
            "source=primary version=" +
            announcement.version +
            " reason=" +
            reason,
          )
          return Err(reason)
        }
        None => ()
      }
    }
    None => ()
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
/// core's own work directory, which is created 0700 on first open; an explicit
/// value must resolve to the same real path or the open is refused.
pub async fn NodeHost::open(
  runtime_id : String,
  state_base~ : String = "",
  workspace_root~ : String = "",
  home~ : String = "",
  policy~ : PolicyGate? = None,
  pty_limits~ : @pty_runtime.PtyLimits? = None,
  git_limits~ : @git_runtime.GitLimits? = None,
) -> Result[NodeHost, String] {
  if !@transport.is_safe_id(runtime_id) {
    return Err("invalid runtime id")
  }
  let effective_home = if home.trim() != "" {
    home.trim().to_owned()
  } else {
    node_default_home()
  }
  if effective_home != "" &&
    (!effective_home.has_prefix("/") || effective_home.contains("/../")) {
    return Err("node home must be an absolute normalised path")
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
  // The execution root is the runtime core's work directory. fs, PTY, git and
  // exec must all name the same real directory, otherwise a policy digest
  // could classify one path while exec children run in another. An explicit
  // `--workspace` is accepted only when it resolves to that same real root.
  let execution_root = @fs.realpath(executor.state_root() + "/work") catch {
    error => {
      executor.close()
      return Err("cannot resolve the runtime execution root: " + error.to_string())
    }
  }
  if workspace_root.trim() != "" {
    let requested_real = @fs.realpath(workspace_root.trim()) catch {
      error => {
        executor.close()
        return Err(
          "cannot resolve the requested workspace root: " + error.to_string(),
        )
      }
    }
    if requested_real != execution_root {
      executor.close()
      return Err(
        "an explicit workspace root must resolve to the runtime execution root (" +
        execution_root +
        "); exec, fs, PTY and git all run there",
      )
    }
  }
  let workspace = match @runtime.RootedDir::open(execution_root) {
    Ok(value) => value
    Err(message) => {
      executor.close()
      return Err("cannot open runtime workspace: " + message)
    }
  }
  // The environment root is the only filesystem outside the workspace the
  // node exposes (A2.2). It is created 0700 and opened as a rooted directory;
  // a node without a home cannot host environments and says so.
  let (environment_root, environments) : (String, @runtime.RootedDir?) = if effective_home == "" {
    ("", None)
  } else {
    let root = effective_home + "/" + NODE_ENVIRONMENT_DIR_NAME
    @fs.mkdir(root, permission=0o700, recursive=true, allow_exist=true) catch {
      error => {
        executor.close()
        return Err(
          "cannot create the environment root: " + error.to_string(),
        )
      }
    }
    @fs.chmod(root, 0o700) catch { _ => () }
    match @transport.validate_private_dir(root, "environment root") {
      Ok(_) => ()
      Err(message) => {
        executor.close()
        return Err(message)
      }
    }
    let rooted = match @runtime.RootedDir::open(root) {
      Ok(value) => value
      Err(message) => {
        executor.close()
        return Err("cannot open the environment root: " + message)
      }
    }
    (rooted.root(), Some(rooted))
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
  // Restore crash-safe replay memory. Both files are 0600 in the 0700 state
  // dir; a malformed store fails the open instead of silently forgetting a
  // consumed nonce or an accepted-but-unanswered mutation.
  let nonces = match
    load_consumed_nonces(
      state_dir + "/" + NODE_NONCES_FILE_NAME,
      @async.now(),
    ) {
    Ok(value) => value
    Err(message) => {
      executor.close()
      return Err(message)
    }
  }
  let durable = match
    DurableIdempotency::open(state_dir + "/" + NODE_IDEMPOTENCY_FILE_NAME) {
    Ok(value) => value
    Err(message) => {
      executor.close()
      return Err(message)
    }
  }
  Ok({
    runtime_id,
    state_dir,
    identity_path,
    token_path: state_dir + "/" + NODE_TOKEN_FILE_NAME,
    home: effective_home,
    environment_root,
    environments,
    executor,
    workspace,
    workspace_root: workspace.root(),
    policy: effective_policy,
    cache: IdempotencyCache::new(),
    durable,
    nonces,
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
  // Report docker only when the CLI resolves on the node PATH: the primary
  // gates environment creation on this, and the environment backend runs
  // docker exclusively through `runtime.exec.*`.
  let capabilities = node_capabilities()
  if program_on_path("docker") {
    capabilities.push("docker")
  }
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(self.runtime_id)),
    (
      "transport_version",
      @contracts.json_string(@transport.PROTOCOL_VERSION_TEXT),
    ),
    ("protocol_version", @contracts.json_int(@transport.PROTOCOL_VERSION)),
    ("capabilities", @contracts.json_string_array(capabilities)),
    (
      "workspace_roots",
      @contracts.json_string_array([self.workspace_root]),
    ),
    ("home", @contracts.json_string(self.home)),
    (
      "environment_root",
      @contracts.json_string(self.environment_root),
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
