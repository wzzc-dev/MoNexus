///|
/// Risk policy, audit records and secret redaction (M6).
///
/// The host is the only place a policy verdict is made. A verdict is recorded
/// as an `audit.recorded` event with the actor, action, risk, outcome and
/// reason, so every decision that gates work is explainable later. Secret
/// values are removed before any audit detail, decision text, log artifact or
/// error string is persisted (ADR-0006 §5).

// ---------------------------------------------------------------------------
// Risk policy
// ---------------------------------------------------------------------------

///|
pub const POLICY_ALLOW : String = "allow"

///|
pub const POLICY_ASK : String = "ask"

///|
pub const POLICY_DENY : String = "deny"

///|
pub const RISK_LOW : String = "low"

///|
pub const RISK_MEDIUM : String = "medium"

///|
pub const RISK_HIGH : String = "high"

///|
pub const RISK_CRITICAL : String = "critical"

///|
/// One policy verdict: what was classified, the risk level, the action and a
/// short human-readable reason that is safe to persist.
pub(all) struct PolicyVerdict {
  risk : String
  action : String
  reason : String
}

///|
pub fn PolicyVerdict::to_json(self : PolicyVerdict) -> @json.Json {
  json_object([
    ("risk", json_string(self.risk)),
    ("action", json_string(self.action)),
    ("reason", json_string(self.reason)),
  ])
}

///|
fn command_has_any(lower : String, needles : Array[String]) -> Bool {
  for needle in needles {
    if lower.contains(needle) {
      return true
    }
  }
  false
}

///|
/// Classify one owner-declared command. `critical` is denied outright, `high`
/// becomes an approval Decision, everything else is allowed inside the
/// Workspace authorization (architecture §11.1). This is a conservative
/// classifier, not a shell parser: the command itself is an owner declaration
/// and is executed as declared.
pub fn evaluate_command_policy(command : String) -> PolicyVerdict {
  let lower = command.to_lower()
  let critical = [
    "sudo ", "sudo\t", "mkfs", "shutdown", "reboot", "poweroff", "halt ",
    "dd if=", "dd of=", "> /dev/sd", "chmod 777 /", "chown -r /",
    "rm -rf /", "rm -fr /", ":(){", "passwd ", "useradd ", "userdel ",
    "iptables ", "nft ", "systemctl ", "launchctl ",
  ]
  if command_has_any(lower, critical) {
    return {
      risk: RISK_CRITICAL,
      action: POLICY_DENY,
      reason: "command touches root/system scope and is denied by policy",
    }
  }
  let high = [
    "rm -rf", "rm -fr", "rm -f", "git push --force", "git push -f",
    "apt install", "apt-get install", "yum install", "dnf install",
    "npm install -g", "npm i -g", "pnpm add -g", "pip install",
    "python -m pip install", "cargo install", "brew install",
    "chmod -r", "chown -r", "kill -9", "pkill", "killall",
    "truncate", "git reset --hard", "git clean -fdx", "git clean -fd",
  ]
  if command_has_any(lower, high) {
    return {
      risk: RISK_HIGH,
      action: POLICY_ASK,
      reason: "command can destroy data or change the machine; owner approval required",
    }
  }
  let low_prefixes = [
    "ls", "cat", "pwd", "echo", "grep", "find", "head", "tail", "wc",
    "stat", "git status", "git diff", "git log", "which", "command -v",
    "true", "uname", "id", "date",
  ]
  let mut read_only = false
  for prefix in low_prefixes {
    if lower == prefix || lower.has_prefix(prefix + " ") {
      read_only = true
    }
  }
  if read_only {
    return {
      risk: RISK_LOW,
      action: POLICY_ALLOW,
      reason: "read-only command",
    }
  }
  {
    risk: RISK_MEDIUM,
    action: POLICY_ALLOW,
    reason: "workspace-scoped command allowed inside the workspace authorization",
  }
}

// ---------------------------------------------------------------------------
// Audit record
// ---------------------------------------------------------------------------

///|
pub const EVENT_AUDIT_RECORDED : String = "audit.recorded"

///|
pub const METHOD_AUDIT_LIST : String = "audit.list"

///|
/// One audit event payload. `action` names the gate that ran, `target` the
/// object it was about, `outcome` the observed result. `detail` is always
/// redacted before persistence.
pub(all) struct AuditRecord {
  id : String
  action : String
  actor : String
  subject : String
  target : String
  policy : String
  risk : String
  outcome : String
  detail : String
  decision_id : String
  run_id : String
  ts : String
}

///|
pub fn AuditRecord::new(
  id~ : String,
  action~ : String,
  actor~ : String,
  subject~ : String,
  outcome~ : String,
  ts~ : String,
  target~ : String = "",
  policy~ : String = "",
  risk~ : String = "",
  detail~ : String = "",
  decision_id~ : String = "",
  run_id~ : String = "",
) -> AuditRecord {
  {
    id,
    action,
    actor,
    subject,
    target,
    policy,
    risk,
    outcome,
    detail: redact_secrets(detail),
    decision_id,
    run_id,
    ts,
  }
}

///|
pub fn AuditRecord::to_json(self : AuditRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("action", json_string(self.action)),
    ("actor", json_string(self.actor)),
    ("subject", json_string(self.subject)),
    ("target", json_string(self.target)),
    ("policy", json_string(self.policy)),
    ("risk", json_string(self.risk)),
    ("outcome", json_string(self.outcome)),
    ("detail", json_string(self.detail)),
    ("decision_id", json_string(self.decision_id)),
    ("run_id", json_string(self.run_id)),
    ("ts", json_string(self.ts)),
  ])
}

///|
pub fn audit_from_json(json : @json.Json) -> AuditRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  Some({
    id,
    action: string_field_or(object, "action", ""),
    actor: string_field_or(object, "actor", ""),
    subject: string_field_or(object, "subject", ""),
    target: string_field_or(object, "target", ""),
    policy: string_field_or(object, "policy", ""),
    risk: string_field_or(object, "risk", ""),
    outcome: string_field_or(object, "outcome", ""),
    detail: string_field_or(object, "detail", ""),
    decision_id: string_field_or(object, "decision_id", ""),
    run_id: string_field_or(object, "run_id", ""),
    ts: string_field_or(object, "ts", ""),
  })
}

///|
pub fn audit_list_result(records : Array[AuditRecord]) -> @json.Json {
  json_object([
    ("audit", json_array(records.map(fn(record) { record.to_json() }))),
  ])
}

///|
pub fn audit_list_from_result(
  json : @json.Json,
) -> Result[Array[AuditRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let items = match object.get("audit") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("result has no audit items")
  }
  let out : Array[AuditRecord] = []
  for item in items {
    match audit_from_json(item) {
      Some(record) => out.push(record)
      None => ()
    }
  }
  Ok(out)
}

///|
pub fn audit_list_params(
  client_request_id : String,
  limit : Int,
  run_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("limit", json_int(limit)),
    ("run_id", json_string(run_id)),
  ])
}

// ---------------------------------------------------------------------------
// Secret redaction
// ---------------------------------------------------------------------------

fn redact_line(line : String) -> String {
  let lower = line.to_lower()
  let keys = [
    "api_key", "apikey", "api-key", "token", "secret", "password", "passwd",
    "authorization", "private_key", "private-key", "access_key",
    "access-key", "credential", "bearer ", "x-api-key",
  ]
  let mut first_at = -1
  for key in keys {
    if first_at >= 0 {
      continue
    }
    match lower.find(key) {
      Some(index) => first_at = index.to_int()
      None => ()
    }
  }
  if first_at < 0 {
    return line
  }
  // Keep only the prefix before the credential-bearing token and redact the
  // rest of the line: over-redaction is preferable to leaking a value.
  let head = if first_at > 0 { line.substring(start=0, end=first_at) } else { "" }
  head + "[redacted]"
}

///|
/// Remove credential-looking values from free text. Used before writing Audit
/// records, Decision detail, run/verify logs and error strings. Handles
/// `KEY=value`, `key: value`, `Bearer value`, private-key blocks and `sk-`
/// API-key tokens.
pub fn redact_secrets(text : String) -> String {
  if text == "" {
    return text
  }
  let lines : Array[String] = []
  let mut in_private_key = false
  for raw in text.split("\n") {
    let line = raw.to_string()
    let lower = line.to_lower()
    if lower.contains("-----begin") && lower.contains("private key") {
      in_private_key = true
      lines.push("-----BEGIN PRIVATE KEY-----[redacted]")
      continue
    }
    if in_private_key {
      if lower.contains("-----end") && lower.contains("private key") {
        in_private_key = false
        lines.push("-----END PRIVATE KEY-----")
      }
      continue
    }
    let mut cleaned = redact_line(line)
    // A5: proxy capability tokens (`mxp_`) and node lease tokens (`mxs_`) are
    // credential-shaped. Redact them even when no key name precedes them.
    cleaned = redact_prefixed_tokens(cleaned, "mxp_")
    cleaned = redact_prefixed_tokens(cleaned, "mxs_")
    // Redact inline `sk-...` API keys that do not sit behind a key name.
    cleaned = redact_sk_tokens(cleaned)
    lines.push(cleaned)
  }
  lines.join("\n")
}

///|
/// Redact every `prefix`-headed token (for example `mxp_...` or `mxs_...`) up
/// to the next whitespace. Over-redaction is intentional: a token that reaches
/// a persisted surface must never be readable again.
fn redact_prefixed_tokens(line : String, prefix : String) -> String {
  let lower = line.to_lower()
  let wanted = prefix.to_lower()
  if !lower.contains(wanted) {
    return line
  }
  let mut out = ""
  let mut index = 0
  let plen = wanted.length()
  while index < line.length() {
    let matches_prefix = index + plen <= line.length() &&
      lower.substring(start=index, end=index + plen) == wanted
    if matches_prefix {
      let mut cursor = index + plen
      while cursor < line.length() {
        let ch = line.substring(start=cursor, end=cursor + 1)
        if ch == " " || ch == "\t" || ch == "\"" || ch == "'" || ch == "," ||
          ch == ")" || ch == "]" {
          break
        }
        cursor = cursor + 1
      }
      out = out + prefix + "[redacted]"
      index = cursor
    } else {
      out = out + line.substring(start=index, end=index + 1)
      index = index + 1
    }
  }
  out
}

fn redact_sk_tokens(line : String) -> String {  if !line.to_lower().contains("sk-") {
    return line
  }
  let lower = line.to_lower()
  let mut out = ""
  let mut index = 0
  while index < line.length() {
    let matches_sk = index + 3 <= line.length() &&
      lower.substring(start=index, end=index + 3) == "sk-"
    if matches_sk {
      let mut cursor = index + 3
      while cursor < line.length() {
        let ch = match line.get_char(cursor) {
          Some(value) => value
          None => break
        }
        let token_char = (ch >= 'a' && ch <= 'z') ||
          (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch == '-' || ch == '_'
        if !token_char {
          break
        }
        cursor = cursor + 1
      }
      if cursor - index >= 11 {
        out = out + "sk-[redacted]"
      } else {
        out = out + line.substring(start=index, end=cursor)
      }
      index = cursor
    } else {
      match line.get_char(index) {
        Some(ch) => out = out + ch.to_string()
        None => ()
      }
      index = index + 1
    }
  }
  out
}

// ---------------------------------------------------------------------------
// Inbox buckets
// ---------------------------------------------------------------------------

///|
pub const INBOX_NEEDS_YOU : String = "needs_you"

///|
pub const INBOX_WAITING : String = "waiting"

///|
pub const INBOX_HANDLED : String = "handled"

///|
/// Inbox section for one Decision: pending needs the owner; an answered
/// retry/approval is waiting while the run it created is still active; every
/// other answer and every expiry is handled. Kept in contracts so host and
/// desktop share one rule.
pub fn decision_inbox_bucket(
  status : String,
  kind : String,
  option_id : String,
  run_status : String,
) -> String {
  if status == "pending" {
    return INBOX_NEEDS_YOU
  }
  if status == "answered" {
    let opens_work = option_id == "retry" || option_id == "approve" ||
      option_id == "allow_once" || option_id == "allow_always"
    if opens_work && run_is_active_status(run_status) {
      return INBOX_WAITING
    }
    if kind == "permission" && run_status == "" {
      // A permission answer resumes the Agent session; the Inbox no longer
      // needs the owner even though the session keeps running.
      return INBOX_HANDLED
    }
  }
  INBOX_HANDLED
}

///|
fn run_is_active_status(status : String) -> Bool {
  status == "queued" || status == "running" || status == "verifying" ||
  status == "waiting_approval" || status == "waiting_input" ||
  status == "lost"
}

///|
/// Whether an environment/parameter name looks like a credential holder.
/// `agent_env` values for these names are replaced with `[redacted]` before a
/// Run is persisted: credentials stay with the machine's logged-in Agent
/// account (ADR-0006 §5), never in the host log or event payload.
pub fn is_secret_key_name(name : String) -> Bool {
  let lower = name.to_lower()
  lower.contains("token") ||
  lower.contains("secret") ||
  lower.contains("password") ||
  lower.contains("passwd") ||
  lower.contains("api_key") ||
  lower.contains("apikey") ||
  lower.contains("api-key") ||
  lower.contains("private_key") ||
  lower.contains("access_key") ||
  lower.contains("credential")
}
