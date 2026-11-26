///|
/// Risk classification for the remote execution surface (ADR-0012 §5).
///
/// The classifier is conservative and does not parse shell grammar: the
/// runtime executes an argv array without a shell, so pattern matching is
/// applied to the lowercased joined argv and can only over-classify. High-risk
/// categories are installers, host mounts, destructive/delete operations,
/// privilege elevation, and arbitrary `sh -c`-style execution; a snapshot may
/// add its own high-risk and deny rules.
///
/// The four outcomes are:
///
/// * `Allow` — low-risk read-only work the snapshot permits, or an operation
///   the snapshot explicitly allows while it is fresh and the primary is
///   reachable. Reported with the policy version.
/// * `ApprovalRequired` — high-risk/unknown work; the primary must issue a
///   bound approval grant. Includes the stable command digest.
/// * `Deny` — explicitly forbidden by built-in rules or the snapshot.
/// * `Unverifiable` — no trustworthy snapshot, a stale snapshot, or an
///   unreachable primary while the operation is not locally permitted. The
///   caller must wait; it must never treat this as allow.

///|
pub const ACTION_UNVERIFIABLE : String = "unverifiable"

///|
pub(all) enum DecisionKind {
  Allow
  ApprovalRequired
  Deny
  Unverifiable
}

///|
pub fn DecisionKind::label(self : DecisionKind) -> String {
  match self {
    Allow => "allow"
    ApprovalRequired => "approval_required"
    Deny => "deny"
    Unverifiable => "unverifiable"
  }
}

///|
fn action_for(kind : DecisionKind) -> String {
  match kind {
    Allow => @contracts.POLICY_ALLOW
    ApprovalRequired => @contracts.POLICY_ASK
    Deny => @contracts.POLICY_DENY
    Unverifiable => ACTION_UNVERIFIABLE
  }
}

///|
pub(all) struct PolicyDecision {
  kind : DecisionKind
  risk : String
  action : String
  reason : String
  digest : String
  policy_version : String
  policy_hash : String
}

///|
fn make_decision(
  kind : DecisionKind,
  risk : String,
  reason : String,
  digest : String,
  policy_version : String,
  policy_hash : String,
) -> PolicyDecision {
  {
    kind,
    risk,
    action: action_for(kind),
    reason,
    digest,
    policy_version,
    policy_hash,
  }
}

///|
pub fn PolicyDecision::is_allowed(self : PolicyDecision) -> Bool {
  match self.kind {
    Allow => true
    _ => false
  }
}

///|
/// Whether the caller must wait (for a fresh snapshot or the primary's
/// approval) instead of executing.
pub fn PolicyDecision::needs_primary(self : PolicyDecision) -> Bool {
  match self.kind {
    Allow => false
    _ => true
  }
}

///|
/// The decision shape shared with the host's policy/audit vocabulary. The
/// `unverifiable` action is local to the runtime surface and therefore has no
/// existing contracts constant.
pub fn PolicyDecision::verdict(self : PolicyDecision) -> @contracts.PolicyVerdict {
  { risk: self.risk, action: self.action, reason: self.reason }
}

///|
pub fn PolicyDecision::to_json(self : PolicyDecision) -> @json.Json {
  @contracts.json_object([
    ("action", @contracts.json_string(self.action)),
    ("digest", @contracts.json_string(self.digest)),
    ("kind", @contracts.json_string(self.kind.label())),
    ("policy_hash", @contracts.json_string(self.policy_hash)),
    ("policy_version", @contracts.json_string(self.policy_version)),
    ("reason", @contracts.json_string(self.reason)),
    ("risk", @contracts.json_string(self.risk)),
  ])
}

///|
/// Canonical JSON encoding of a decision, for transport diagnostics. It
/// carries no argv/env values, only the digest, labels and reason.
pub fn PolicyDecision::encode(self : PolicyDecision) -> String {
  "{" +
  "\"action\":" + canonical_quote(self.action) + "," +
  "\"digest\":" + canonical_quote(self.digest) + "," +
  "\"kind\":" + canonical_quote(self.kind.label()) + "," +
  "\"policy_hash\":" + canonical_quote(self.policy_hash) + "," +
  "\"policy_version\":" + canonical_quote(self.policy_version) + "," +
  "\"reason\":" + canonical_quote(self.reason) + "," +
  "\"risk\":" + canonical_quote(self.risk) + "}"
}

// ---------------------------------------------------------------------------
// Policy source
// ---------------------------------------------------------------------------

///|
/// Where the runtime's policy came from. `Missing` and `Invalid` are explicit
/// so the classifier cannot accidentally treat "no snapshot" as "allow all".
pub(all) enum PolicySource {
  Loaded(PolicySnapshot)
  Missing(String)
  Invalid(String)
}

///|
pub(all) struct PolicyContext {
  policy : PolicySource
  now_ms : Int64
  primary_reachable : Bool
}

///|
pub fn PolicyContext::with_snapshot(
  snapshot : PolicySnapshot,
  now_ms~ : Int64,
  primary_reachable~ : Bool,
) -> PolicyContext {
  { policy: Loaded(snapshot), now_ms, primary_reachable }
}

///|
pub fn PolicyContext::missing(
  reason~ : String,
  now_ms~ : Int64,
  primary_reachable~ : Bool,
) -> PolicyContext {
  { policy: Missing(reason), now_ms, primary_reachable }
}

///|
pub fn PolicyContext::invalid(
  reason~ : String,
  now_ms~ : Int64,
  primary_reachable~ : Bool,
) -> PolicyContext {
  { policy: Invalid(reason), now_ms, primary_reachable }
}

///|
fn PolicyContext::policy_version(self : PolicyContext) -> String {
  match self.policy {
    Loaded(snapshot) => snapshot.version
    _ => ""
  }
}

///|
fn PolicyContext::policy_hash(self : PolicyContext) -> String {
  match self.policy {
    Loaded(snapshot) => snapshot.content_hash
    _ => ""
  }
}

// ---------------------------------------------------------------------------
// Built-in classification
// ---------------------------------------------------------------------------

///|
priv enum BuiltinClass {
  Critical(String)
  High(String)
  Low
  Medium
}

///|
fn contains_any_token(tokens : Array[String], names : Array[String]) -> Bool {
  for token in tokens {
    if names.contains(token) {
      return true
    }
  }
  false
}

///|
fn looks_like_installer(tokens : Array[String]) -> Bool {
  let managers : Array[String] = [
    "apt", "apt-get", "aptitude", "yum", "dnf", "zypper", "pacman", "apk",
    "brew", "port", "pip", "pip3", "pipx", "conda", "mamba", "poetry", "npm",
    "pnpm", "yarn", "bun", "cargo", "gem", "go", "composer", "nix", "nix-env",
    "uv", "make", "ninja", "dpkg", "rpm",
  ]
  let verbs : Array[String] = [
    "install", "add", "i", "ci", "-g", "--global", "global", "upgrade",
    "reinstall", "require", "-i", "-s", "--install",
  ]
  let mut index = 0
  while index < tokens.length() {
    if managers.contains(tokens[index]) {
      let mut cursor = index + 1
      while cursor < tokens.length() {
        if verbs.contains(tokens[cursor]) {
          return true
        }
        cursor = cursor + 1
      }
    }
    index = index + 1
  }
  false
}

///|
fn looks_like_shell_invocation(tokens : Array[String]) -> Bool {
  let shells : Array[String] = [
    "sh", "bash", "zsh", "dash", "fish", "ksh", "csh", "tcsh",
  ]
  let mut index = 0
  while index + 1 < tokens.length() {
    if shells.contains(tokens[index]) && tokens[index + 1] == "-c" {
      return true
    }
    index = index + 1
  }
  false
}

///|
fn looks_like_pipe_to_shell(text : String) -> Bool {
  text_has_any(
    text,
    ["| sh", "|sh", "| bash", "|bash", "| zsh", "|zsh", "| dash", "|dash"],
  )
}

///|
fn builtin_deny_reason(tokens : Array[String], text : String) -> String? {
  let denied_tokens : Array[String] = [
    "shutdown", "reboot", "poweroff", "halt", "fdisk", "parted", "wipefs",
    "useradd", "userdel", "groupadd", "groupdel", "passwd", "systemctl",
    "service", "launchctl", "initctl", "iptables", "nft",
  ]
  for token in tokens {
    if denied_tokens.contains(token) || token.has_prefix("mkfs") {
      return Some("command touches root or system scope and is denied by policy")
    }
  }
  let denied_patterns : Array[String] = [
    ":(){", "dd if=", "dd of=/dev/", "chmod 777 /", "chown -r /", "rm -rf /",
    "rm -fr /", "> /dev/sd", "> /dev/nvme", "> /dev/hd",
  ]
  if text_has_any(text, denied_patterns) {
    return Some("command matches a denied destructive pattern")
  }
  None
}

///|
fn builtin_high_reason(tokens : Array[String], text : String) -> String? {
  let privilege : Array[String] = [
    "sudo", "doas", "su", "pkexec", "runuser", "sudoedit", "setcap",
  ]
  if contains_any_token(tokens, privilege) {
    return Some("privilege elevation requires owner approval")
  }
  if looks_like_shell_invocation(tokens) || looks_like_pipe_to_shell(text) ||
    contains_any_token(tokens, ["eval"]) {
    return Some("arbitrary shell execution requires owner approval")
  }
  let mounts : Array[String] = [
    "mount", "umount", "fusermount", "nsenter", "chroot", "pivot_root",
  ]
  let containers : Array[String] = ["docker", "podman", "nerdctl", "containerd"]
  if contains_any_token(tokens, mounts) ||
    contains_any_token(tokens, containers) {
    return Some("host mount or container operation requires owner approval")
  }
  if looks_like_installer(tokens) {
    return Some("installer command requires owner approval")
  }
  let destructive : Array[String] = [
    "rm", "rmdir", "unlink", "shred", "truncate", "kill", "pkill", "killall",
    "dd",
  ]
  if contains_any_token(tokens, destructive) {
    return Some("destructive or process-killing operation requires owner approval")
  }
  if contains_any_token(tokens, ["find"]) &&
    contains_any_token(tokens, ["-delete", "-exec", "-execdir", "-ok"]) {
    return Some("find with -delete/-exec requires owner approval")
  }
  if contains_any_token(tokens, ["chmod", "chown"]) &&
    contains_any_token(tokens, ["-r", "--recursive"]) {
    return Some("recursive permission change requires owner approval")
  }
  if contains_any_token(tokens, ["git"]) {
    if contains_any_token(tokens, ["clean"]) ||
      (contains_any_token(tokens, ["reset"]) &&
      contains_any_token(tokens, ["--hard"])) ||
      (contains_any_token(tokens, ["push"]) &&
      contains_any_token(tokens, ["-f", "--force", "--force-with-lease"])) {
      return Some("destructive git operation requires owner approval")
    }
  }
  if contains_any_token(tokens, ["env", "printenv"]) {
    return Some("environment dump may expose credentials and requires owner approval")
  }
  None
}

///|
fn is_read_only_argv(argv : Array[String]) -> Bool {
  if argv.length() == 0 {
    return false
  }
  let tokens : Array[String] = []
  for item in argv {
    tokens.push(command_basename(item))
  }
  let command = tokens[0]
  let simple : Array[String] = [
    "ls", "cat", "pwd", "echo", "printf", "grep", "head", "tail", "wc",
    "stat", "which", "true", "uname", "id", "date", "file", "du", "df", "ps",
    "hostname", "sha256sum", "md5sum", "cut", "tr", "basename", "dirname",
    "realpath", "readlink", "tree", "diff", "cmp", "nl", "rev", "tac",
    "column",
  ]
  if simple.contains(command) {
    return true
  }
  if command == "find" {
    return !contains_any_token(tokens, ["-delete", "-exec", "-execdir", "-ok"])
  }
  if command == "sort" {
    return !contains_any_token(tokens, ["-o", "--output"])
  }
  if command == "sed" {
    return !contains_any_token(tokens, ["-i", "--in-place"])
  }
  if command == "git" {
    if tokens.length() < 2 {
      return false
    }
    let sub = tokens[1]
    let read_subcommands : Array[String] = [
      "status", "diff", "log", "show", "rev-parse", "blame", "describe",
      "shortlog", "ls-files", "cat-file", "show-ref", "whatchanged",
    ]
    if read_subcommands.contains(sub) {
      return !contains_any_token(tokens, ["--ext-diff"])
    }
    if sub == "branch" || sub == "tag" {
      let mut index = 2
      while index < tokens.length() {
        if !tokens[index].has_prefix("-") {
          return false
        }
        index = index + 1
      }
      return true
    }
    if sub == "remote" {
      return contains_any_token(tokens, ["-v", "--verbose"])
    }
    if sub == "stash" && tokens.length() >= 3 && tokens[2] == "list" {
      return true
    }
    false
  } else {
    false
  }
}

///|
fn classify_builtin(request : ExecutionRequest) -> BuiltinClass {
  let tokens : Array[String] = []
  for item in request.argv {
    tokens.push(command_basename(item))
  }
  let text = command_text(request.argv)
  match builtin_deny_reason(tokens, text) {
    Some(reason) => return Critical(reason)
    None => ()
  }
  match builtin_high_reason(tokens, text) {
    Some(reason) => return High(reason)
    None => ()
  }
  match request.operation {
    FsDelete => return High("file deletion requires owner approval")
    Control => return Low
    _ => ()
  }
  if request.operation.is_read_only() {
    return Low
  }
  if is_read_only_argv(request.argv) {
    return Low
  }
  Medium
}

// ---------------------------------------------------------------------------
// Snapshot rule checks
// ---------------------------------------------------------------------------

///|
fn env_not_allowed(
  rules : PolicyRules,
  env_names : Array[String],
) -> String? {
  for name in env_names {
    if !rules.env_allowlist.contains(name) {
      return Some(name)
    }
  }
  None
}

///|
fn snapshot_deny_reason(
  snapshot : PolicySnapshot,
  request : ExecutionRequest,
) -> String? {
  let operation = request.operation.label()
  if snapshot.rules.denied_operations.contains(operation) {
    return Some(
      "operation " + operation + " is denied by policy " + snapshot.version,
    )
  }
  let text = command_text(request.argv)
  if text_has_any(text, snapshot.rules.denied_patterns) {
    return Some("command matches a pattern denied by policy " + snapshot.version)
  }
  None
}

///|
fn snapshot_high_reason(
  snapshot : PolicySnapshot,
  request : ExecutionRequest,
) -> String? {
  let operation = request.operation.label()
  if snapshot.rules.high_risk_operations.contains(operation) {
    return Some(
      "operation " + operation + " is high risk under policy " + snapshot.version,
    )
  }
  let text = command_text(request.argv)
  if text_has_any(text, snapshot.rules.high_risk_patterns) {
    return Some(
      "command matches a high-risk pattern in policy " + snapshot.version,
    )
  }
  None
}

///|
fn argv_prefix_allowed(
  rules : PolicyRules,
  request : ExecutionRequest,
) -> Bool {
  let text = command_text(request.argv)
  for prefix in rules.allowed_argv_prefixes {
    let needle = prefix.to_lower()
    if text == needle || text.has_prefix(needle + " ") {
      return true
    }
  }
  false
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

///|
/// Classify one request against the available policy. This is the only entry
/// point the runtime calls before executing; there is no default-allow path.
pub fn evaluate(
  context : PolicyContext,
  request : ExecutionRequest,
) -> PolicyDecision {
  let digest = request.digest()
  let version = context.policy_version()
  let hash = context.policy_hash()
  let builtin = classify_builtin(request)
  let builtin_risk = match builtin {
    Critical(_) => @contracts.RISK_CRITICAL
    High(_) => @contracts.RISK_HIGH
    Low => @contracts.RISK_LOW
    Medium => @contracts.RISK_MEDIUM
  }
  // Malformed requests and built-in catastrophic commands are denied without
  // needing a snapshot: deny is fail-closed and does not depend on trust.
  match request.validate() {
    Some(reason) =>
      return make_decision(
        Deny,
        @contracts.RISK_HIGH,
        reason,
        digest,
        version,
        hash,
      )
    None => ()
  }
  match builtin {
    Critical(reason) =>
      return make_decision(
        Deny,
        @contracts.RISK_CRITICAL,
        reason,
        digest,
        version,
        hash,
      )
    _ => ()
  }
  let snapshot = match context.policy {
    Loaded(value) => value
    Missing(reason) =>
      return make_decision(
        Unverifiable,
        builtin_risk,
        "policy snapshot is missing (" + reason +
        "); the operation cannot be verified without a trusted policy",
        digest,
        version,
        hash,
      )
    Invalid(reason) =>
      return make_decision(
        Unverifiable,
        builtin_risk,
        "policy snapshot is invalid (" + reason +
        "); the operation cannot be verified without a trusted policy",
        digest,
        version,
        hash,
      )
  }
  match env_not_allowed(snapshot.rules, request.env_names) {
    Some(name) =>
      return make_decision(
        Deny,
        @contracts.RISK_HIGH,
        "environment variable " + name + " is not permitted by policy " +
        snapshot.version,
        digest,
        version,
        hash,
      )
    None => ()
  }
  match snapshot_deny_reason(snapshot, request) {
    Some(reason) =>
      return make_decision(
        Deny,
        @contracts.RISK_CRITICAL,
        reason,
        digest,
        version,
        hash,
      )
    None => ()
  }
  let fresh = snapshot.is_fresh(context.now_ms)
  let online = context.primary_reachable
  let high : String? = match builtin {
    High(reason) => Some(reason)
    _ => snapshot_high_reason(snapshot, request)
  }
  match high {
    Some(reason) => {
      if fresh && online {
        return make_decision(
          ApprovalRequired,
          @contracts.RISK_HIGH,
          reason + " (policy " + snapshot.version + ")",
          digest,
          version,
          hash,
        )
      }
      let why = if !fresh { "policy is stale" } else { "primary is unreachable" }
      return make_decision(
        Unverifiable,
        @contracts.RISK_HIGH,
        reason + "; " + why + ", so the operation must wait (policy " +
        snapshot.version + ")",
        digest,
        version,
        hash,
      )
    }
    None => ()
  }
  let read_only = match builtin {
    Low => true
    _ => false
  }
  if read_only && snapshot.rules.allow_read_only {
    return make_decision(
      Allow,
      @contracts.RISK_LOW,
      "read-only operation allowed locally by policy " + snapshot.version,
      digest,
      version,
      hash,
    )
  }
  let explicitly_allowed = snapshot.rules.allowed_operations.contains(
    request.operation.label(),
  ) || argv_prefix_allowed(snapshot.rules, request)
  if explicitly_allowed {
    if fresh && online {
      return make_decision(
        Allow,
        @contracts.RISK_MEDIUM,
        "operation allowed by policy " + snapshot.version,
        digest,
        version,
        hash,
      )
    }
    let why = if !fresh { "policy is stale" } else { "primary is unreachable" }
    return make_decision(
      Unverifiable,
      @contracts.RISK_MEDIUM,
      "operation is allowed only while the policy is fresh and the primary is reachable; " +
      why + " (policy " + snapshot.version + ")",
      digest,
      version,
      hash,
    )
  }
  if fresh && online {
    return make_decision(
      ApprovalRequired,
      builtin_risk,
      "operation is not explicitly allowed by policy " + snapshot.version +
      "; owner approval is required",
      digest,
      version,
      hash,
    )
  }
  let why = if !fresh { "policy is stale" } else { "primary is unreachable" }
  make_decision(
    Unverifiable,
    builtin_risk,
    "operation is not locally permitted and the " + why +
    "; it must wait for a fresh policy and primary approval (policy " +
    snapshot.version + ")",
    digest,
    version,
    hash,
  )
}
