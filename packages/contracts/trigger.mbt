///|
/// Trigger contracts (ADR-0014, A3.0).
///
/// A trigger is a host-owned object that can only *create a Task* through the
/// existing Task/Run path. It never executes commands, never writes a
/// Workspace, never answers a Decision and never becomes a second source of
/// truth for events or scheduling. This file is pure: matching, template
/// rendering, canonical config hashing, rate buckets and payload builders live
/// here so the host and the tests share one definition.
///
/// A3.0 implements event triggers only. `schedule` and `webhook` types exist
/// for forward compatibility (ADR-0014 §3–§4, A3.1); creating one returns
/// `unsupported` and no dispatcher for them exists.

// ---------------------------------------------------------------------------
// Object vocabulary
// ---------------------------------------------------------------------------

///|
pub const TRIGGER_TYPE_EVENT : String = "event"

///|
pub const TRIGGER_TYPE_SCHEDULE : String = "schedule"

///|
pub const TRIGGER_TYPE_WEBHOOK : String = "webhook"

///|
pub const TRIGGER_STATE_ACTIVE : String = "active"

///|
pub const TRIGGER_STATE_DISABLED : String = "disabled"

///|
pub const TRIGGER_STATE_EXPIRED : String = "expired"

///|
/// The `source` field of a `trigger.fired` / `trigger.rejected` payload. It
/// names which input produced the fire, not the trigger type: a manual test
/// fire on an event trigger is `manual`.
pub const TRIGGER_SOURCE_EVENT : String = "event"

///|
pub const TRIGGER_SOURCE_SCHEDULE : String = "schedule"

///|
pub const TRIGGER_SOURCE_WEBHOOK : String = "webhook"

///|
pub const TRIGGER_SOURCE_MANUAL : String = "manual"

///|
pub const TRIGGER_REJECT_DISABLED : String = "disabled"

///|
pub const TRIGGER_REJECT_EXPIRED : String = "expired"

///|
pub const TRIGGER_REJECT_RATE_LIMITED : String = "rate_limited"

///|
pub const TRIGGER_REJECT_CASCADE_DEPTH : String = "cascade_depth"

///|
pub const TRIGGER_REJECT_MISSED_WINDOW : String = "missed_window"

///|
pub const TRIGGER_REJECT_HISTORY_GAP : String = "history_gap"

///|
pub const TRIGGER_REJECT_CLOCK_SKEW : String = "clock_skew"

///|
pub const TRIGGER_REJECT_INVALID_TARGET : String = "invalid_target"

///|
pub const TRIGGER_REJECT_POLICY_DENIED : String = "policy_denied"

///|
pub const TRIGGER_REJECT_INVALID_SIGNATURE : String = "invalid_signature"

///|
pub const TRIGGER_REJECT_UNKNOWN_KEY : String = "unknown_key"

///|
pub const TRIGGER_REJECT_STALE_TIMESTAMP : String = "stale_timestamp"

///|
pub const TRIGGER_REJECT_NONCE_REUSE : String = "nonce_reuse"

///|
pub const TRIGGER_REJECT_SOURCE_DENIED : String = "source_denied"

///|
pub const TRIGGER_REJECT_PAYLOAD_TOO_LARGE : String = "payload_too_large"

///|
pub const TRIGGER_REJECT_UNSUPPORTED : String = "unsupported"

// ---------------------------------------------------------------------------
// RPC methods and event types
// ---------------------------------------------------------------------------

///|
pub const METHOD_TRIGGER_CREATE : String = "trigger.create"

///|
pub const METHOD_TRIGGER_LIST : String = "trigger.list"

///|
pub const METHOD_TRIGGER_GET : String = "trigger.get"

///|
pub const METHOD_TRIGGER_UPDATE : String = "trigger.update"

///|
pub const METHOD_TRIGGER_DISABLE : String = "trigger.disable"

///|
pub const METHOD_TRIGGER_FIRE : String = "trigger.fire"

///|
/// Declared for forward compatibility with ADR-0014 §4.3 / A3.1. A3.0 hosts
/// answer `unsupported`; no key material or webhook route exists yet.
pub const METHOD_TRIGGER_SOURCE_ADD : String = "trigger.source.add"

///|
pub const METHOD_TRIGGER_SOURCE_REVOKE : String = "trigger.source.revoke"

///|
pub const EVENT_TRIGGER_CREATED : String = "trigger.created"

///|
pub const EVENT_TRIGGER_UPDATED : String = "trigger.updated"

///|
pub const EVENT_TRIGGER_DISABLED : String = "trigger.disabled"

///|
pub const EVENT_TRIGGER_EXPIRED : String = "trigger.expired"

///|
pub const EVENT_TRIGGER_FIRED : String = "trigger.fired"

///|
pub const EVENT_TRIGGER_REJECTED : String = "trigger.rejected"

// ---------------------------------------------------------------------------
// Limits (ADR-0014 §6.1)
// ---------------------------------------------------------------------------

///|
pub const TRIGGER_MAX_ACTIVE_DEFAULT : Int = 128

///|
pub const TRIGGER_MAX_ACTIVE_HARD : Int = 512

///|
pub const TRIGGER_EVENT_RATE_PER_MIN : Int = 30

///|
pub const TRIGGER_EVENT_RATE_BURST : Int = 10

///|
pub const TRIGGER_GLOBAL_RATE_PER_MIN : Int = 300

///|
pub const TRIGGER_GLOBAL_RATE_BURST : Int = 300

///|
pub const TRIGGER_EVENT_BATCH : Int = 500

///|
pub const TRIGGER_MAX_CASCADE_DEPTH : Int = 8

///|
/// Saturating counter cap for `dedupe_hits`. A replay storm must not overflow
/// the diagnostic counter or grow the projection without bound.
pub const TRIGGER_DEDUPE_HITS_CAP : Int = 1_000_000

///|
pub const TRIGGER_DEDUPE_RETENTION_DAYS : Int = 90

///|
pub const TRIGGER_TITLE_MAX : Int = 200

///|
pub const TRIGGER_GOAL_MAX : Int = 4_000

///|
pub const TRIGGER_SUBJECT_PREFIX_MAX : Int = 64

///|
pub const TRIGGER_CORRELATION_MAX : Int = 128

///|
pub const TRIGGER_NAME_MAX : Int = 64

///|
pub const TRIGGER_RENDER_VALUE_MAX : Int = 512

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

///|
/// Task template carried by every trigger. It deliberately has no `command`,
/// `argv`, `env`, `shell`, `machine_id`, `worktree_id`, `policy` or
/// `approval` field: a trigger can only ask for an Agent Task, never for a
/// command or an approval exemption (ADR-0014 §1.2).
pub(all) struct TriggerTarget {
  title_template : String
  goal_template : String
  agent_id : String
  workspace_id : String
  project_id : String
  verify : Array[String]
  start_run : Bool
}

///|
pub fn TriggerTarget::new(
  title_template~ : String,
  goal_template~ : String = "",
  agent_id~ : String = "",
  workspace_id~ : String = "",
  project_id~ : String = "",
  verify~ : Array[String] = [],
  start_run~ : Bool = false,
) -> TriggerTarget {
  {
    title_template,
    goal_template,
    agent_id,
    workspace_id,
    project_id,
    verify,
    start_run,
  }
}

///|
pub fn TriggerTarget::to_json(self : TriggerTarget) -> @json.Json {
  json_object([
    ("title_template", json_string(self.title_template)),
    ("goal_template", json_string(self.goal_template)),
    ("agent_id", json_string(self.agent_id)),
    ("workspace_id", json_string(self.workspace_id)),
    ("project_id", json_string(self.project_id)),
    ("verify", json_string_array(self.verify)),
    ("start_run", json_bool(self.start_run)),
  ])
}

///|
pub fn trigger_target_from_json(json : @json.Json) -> TriggerTarget? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    title_template: string_field_or(object, "title_template", ""),
    goal_template: string_field_or(object, "goal_template", ""),
    agent_id: string_field_or(object, "agent_id", ""),
    workspace_id: string_field_or(object, "workspace_id", ""),
    project_id: string_field_or(object, "project_id", ""),
    verify: string_array_field(object, "verify"),
    start_run: bool_field_or(object, "start_run", false),
  })
}

///|
/// Trigger source configuration. `event_*` fields drive A3.0 matching; the
/// schedule and webhook fields are persisted for forward compatibility and
/// are never wired in A3.0.
pub(all) struct TriggerSource {
  event_type : String
  subject_prefix : String
  correlation_id : String
  ignore_self : Bool
  schedule_kind : String
  interval_minutes : Int
  at : String
  weekday : Int
  timezone : String
  jitter_s : Int
  missed : String
  payload_fields : Array[String]
  allowed_cidrs : Array[String]
}

///|
pub fn TriggerSource::new(
  event_type~ : String = "",
  subject_prefix~ : String = "",
  correlation_id~ : String = "",
  ignore_self~ : Bool = true,
  schedule_kind~ : String = "",
  interval_minutes~ : Int = 0,
  at~ : String = "",
  weekday~ : Int = 0,
  timezone~ : String = "UTC",
  jitter_s~ : Int = 0,
  missed~ : String = "skip",
  payload_fields~ : Array[String] = [],
  allowed_cidrs~ : Array[String] = [],
) -> TriggerSource {
  {
    event_type,
    subject_prefix,
    correlation_id,
    ignore_self,
    schedule_kind,
    interval_minutes,
    at,
    weekday,
    timezone,
    jitter_s,
    missed,
    payload_fields,
    allowed_cidrs,
  }
}

///|
pub fn TriggerSource::to_json(self : TriggerSource) -> @json.Json {
  json_object([
    ("event_type", json_string(self.event_type)),
    ("subject_prefix", json_string(self.subject_prefix)),
    ("correlation_id", json_string(self.correlation_id)),
    ("ignore_self", json_bool(self.ignore_self)),
    ("schedule_kind", json_string(self.schedule_kind)),
    ("interval_minutes", json_int(self.interval_minutes)),
    ("at", json_string(self.at)),
    ("weekday", json_int(self.weekday)),
    ("timezone", json_string(self.timezone)),
    ("jitter_s", json_int(self.jitter_s)),
    ("missed", json_string(self.missed)),
    ("payload_fields", json_string_array(self.payload_fields)),
    ("allowed_cidrs", json_string_array(self.allowed_cidrs)),
  ])
}

///|
pub fn trigger_source_from_json(json : @json.Json) -> TriggerSource? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    event_type: string_field_or(object, "event_type", ""),
    subject_prefix: string_field_or(object, "subject_prefix", ""),
    correlation_id: string_field_or(object, "correlation_id", ""),
    ignore_self: bool_field_or(object, "ignore_self", true),
    schedule_kind: string_field_or(object, "schedule_kind", ""),
    interval_minutes: int_field_or(object, "interval_minutes", 0),
    at: string_field_or(object, "at", ""),
    weekday: int_field_or(object, "weekday", 0),
    timezone: string_field_or(object, "timezone", "UTC"),
    jitter_s: int_field_or(object, "jitter_s", 0),
    missed: string_field_or(object, "missed", "skip"),
    payload_fields: string_array_field(object, "payload_fields"),
    allowed_cidrs: string_array_field(object, "allowed_cidrs"),
  })
}

///|
/// Provenance recorded on a trigger-created Task and copied into its event
/// payloads. `depth` is the cascade depth; the root trigger id travels with
/// the Task so an indirect A→B→A loop still terminates.
pub(all) struct TriggerOrigin {
  trigger_id : String
  fire_key : String
  root_trigger_id : String
  depth : Int
  source : String
}

///|
pub fn TriggerOrigin::new(
  trigger_id~ : String,
  fire_key~ : String,
  root_trigger_id~ : String,
  depth~ : Int,
  source~ : String,
) -> TriggerOrigin {
  { trigger_id, fire_key, root_trigger_id, depth, source }
}

///|
pub fn TriggerOrigin::to_json(self : TriggerOrigin) -> @json.Json {
  json_object([
    ("kind", json_string("trigger")),
    ("trigger_id", json_string(self.trigger_id)),
    ("fire_key", json_string(self.fire_key)),
    ("root_trigger_id", json_string(self.root_trigger_id)),
    ("depth", json_int(self.depth)),
    ("source", json_string(self.source)),
  ])
}

///|
pub fn trigger_origin_from_json(json : @json.Json) -> TriggerOrigin? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  if string_field_or(object, "kind", "trigger") != "trigger" {
    return None
  }
  let trigger_id = match string_field(object, "trigger_id") {
    Some(value) if value != "" => value
    _ => return None
  }
  Some({
    trigger_id,
    fire_key: string_field_or(object, "fire_key", ""),
    root_trigger_id: string_field_or(object, "root_trigger_id", ""),
    depth: int_field_or(object, "depth", 0),
    source: string_field_or(object, "source", ""),
  })
}

///|
/// One dedupe/audit ledger entry. `fire_key` is namespaced by source:
/// `event:<event_id>`, `slot:<scheduled_for_ms>` or `manual:<request_id>`.
/// `trigger_fires` is not an event log and never becomes state authority.
pub(all) struct TriggerFire {
  id : String
  trigger_id : String
  source : String
  fire_key : String
  event_id : String
  scheduled_for_ms : Int64
  key_id : String
  task_id : String
  run_id : String
  coalesced : Bool
  depth : Int
  created_at : String
}

///|
pub fn TriggerFire::new(
  id~ : String,
  trigger_id~ : String,
  source~ : String,
  fire_key~ : String,
  created_at~ : String,
  event_id~ : String = "",
  scheduled_for_ms~ : Int64 = 0L,
  key_id~ : String = "",
  task_id~ : String = "",
  run_id~ : String = "",
  coalesced~ : Bool = false,
  depth~ : Int = 1,
) -> TriggerFire {
  {
    id,
    trigger_id,
    source,
    fire_key,
    event_id,
    scheduled_for_ms,
    key_id,
    task_id,
    run_id,
    coalesced,
    depth,
    created_at,
  }
}

///|
pub fn TriggerFire::to_json(self : TriggerFire) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("trigger_id", json_string(self.trigger_id)),
    ("source", json_string(self.source)),
    ("fire_key", json_string(self.fire_key)),
    ("event_id", json_string(self.event_id)),
    ("scheduled_for_ms", json_int64(self.scheduled_for_ms)),
    ("key_id", json_string(self.key_id)),
    ("task_id", json_string(self.task_id)),
    ("run_id", json_string(self.run_id)),
    ("coalesced", json_bool(self.coalesced)),
    ("depth", json_int(self.depth)),
    ("created_at", json_string(self.created_at)),
  ])
}

///|
pub fn trigger_fire_from_json(json : @json.Json) -> TriggerFire? {
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
    trigger_id: string_field_or(object, "trigger_id", ""),
    source: string_field_or(object, "source", ""),
    fire_key: string_field_or(object, "fire_key", ""),
    event_id: string_field_or(object, "event_id", ""),
    scheduled_for_ms: int64_field_or(object, "scheduled_for_ms", 0L),
    key_id: string_field_or(object, "key_id", ""),
    task_id: string_field_or(object, "task_id", ""),
    run_id: string_field_or(object, "run_id", ""),
    coalesced: bool_field_or(object, "coalesced", false),
    depth: int_field_or(object, "depth", 1),
    created_at: string_field_or(object, "created_at", ""),
  })
}

///|
/// The trigger projection row. `state` is derived from `enabled` and
/// `expires_at`; it is never a writable field. `dedupe_hits` is a saturating
/// diagnostic counter and is not logged event-by-event (ADR-0014 §6.2).
pub(all) struct TriggerRecord {
  id : String
  org_id : String
  name : String
  kind : String
  enabled : Bool
  expires_at : String
  target : TriggerTarget
  source : TriggerSource
  version : Int
  config_hash : String
  created_by : String
  created_at : String
  updated_at : String
  expired_at : String
  active_from_seq : Int64
  next_fire_at : String
  last_fired_at : String
  dedupe_hits : Int
}

///|
pub fn TriggerRecord::new(
  id~ : String,
  org_id~ : String,
  name~ : String,
  kind~ : String,
  target~ : TriggerTarget,
  source~ : TriggerSource,
  config_hash~ : String,
  created_by~ : String,
  created_at~ : String,
  active_from_seq~ : Int64,
  enabled~ : Bool = true,
  expires_at~ : String = "",
  version~ : Int = 1,
  expired_at~ : String = "",
  next_fire_at~ : String = "",
  last_fired_at~ : String = "",
  dedupe_hits~ : Int = 0,
) -> TriggerRecord {
  {
    id,
    org_id,
    name,
    kind,
    enabled,
    expires_at,
    target,
    source,
    version,
    config_hash,
    created_by,
    created_at,
    updated_at: created_at,
    expired_at,
    active_from_seq,
    next_fire_at,
    last_fired_at,
    dedupe_hits,
  }
}

///|
/// Persistence shape: no derived state, so projection writes stay stable.
pub fn TriggerRecord::to_json(self : TriggerRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("org_id", json_string(self.org_id)),
    ("name", json_string(self.name)),
    ("type", json_string(self.kind)),
    ("enabled", json_bool(self.enabled)),
    ("expires_at", json_string(self.expires_at)),
    ("target", self.target.to_json()),
    ("source", self.source.to_json()),
    ("version", json_int(self.version)),
    ("config_hash", json_string(self.config_hash)),
    ("created_by", json_string(self.created_by)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
    ("expired_at", json_string(self.expired_at)),
    ("active_from_seq", json_int64(self.active_from_seq)),
    ("next_fire_at", json_string(self.next_fire_at)),
    ("last_fired_at", json_string(self.last_fired_at)),
    ("dedupe_hits", json_int(self.dedupe_hits)),
  ])
}

///|
/// RPC shape: adds the derived `state`. `trigger.get` exposes
/// `dedupe_hits`; no secret ever exists on the record to leak.
pub fn TriggerRecord::to_public_json(
  self : TriggerRecord,
  now_ms : Int64,
) -> @json.Json {
  let object = match as_object(self.to_json()) {
    Some(value) => value
    None => return self.to_json()
  }
  object.set("state", json_string(trigger_state_of(self, now_ms)))
  @json.Json::object(object)
}

///|
pub fn trigger_record_from_json(json : @json.Json) -> TriggerRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let target = match object.get("target") {
    Some(value) =>
      match trigger_target_from_json(value) {
        Some(record) => record
        None => return None
      }
    None => return None
  }
  let source = match object.get("source") {
    Some(value) =>
      match trigger_source_from_json(value) {
        Some(record) => record
        None => return None
      }
    None => return None
  }
  Some({
    id,
    org_id: string_field_or(object, "org_id", ORG_LOCAL),
    name: string_field_or(object, "name", ""),
    kind: string_field_or(object, "type", TRIGGER_TYPE_EVENT),
    enabled: bool_field_or(object, "enabled", true),
    expires_at: string_field_or(object, "expires_at", ""),
    target,
    source,
    version: int_field_or(object, "version", 1),
    config_hash: string_field_or(object, "config_hash", ""),
    created_by: string_field_or(object, "created_by", ""),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    expired_at: string_field_or(object, "expired_at", ""),
    active_from_seq: int64_field_or(object, "active_from_seq", 0L),
    next_fire_at: string_field_or(object, "next_fire_at", ""),
    last_fired_at: string_field_or(object, "last_fired_at", ""),
    dedupe_hits: int_field_or(object, "dedupe_hits", 0),
  })
}

// ---------------------------------------------------------------------------
// Derived state and expiry
// ---------------------------------------------------------------------------

///|
pub fn trigger_state_of(record : TriggerRecord, now_ms : Int64) -> String {
  if !record.enabled {
    return TRIGGER_STATE_DISABLED
  }
  if trigger_is_expired_at(record.expires_at, now_ms) {
    return TRIGGER_STATE_EXPIRED
  }
  TRIGGER_STATE_ACTIVE
}

///|
pub fn trigger_is_active_at(record : TriggerRecord, now_ms : Int64) -> Bool {
  trigger_state_of(record, now_ms) == TRIGGER_STATE_ACTIVE
}

///|
pub fn trigger_is_expired_at(expires_at : String, now_ms : Int64) -> Bool {
  if expires_at == "" {
    return false
  }
  match trigger_parse_rfc3339_ms(expires_at) {
    Some(value) => value <= now_ms
    None => false
  }
}

///|
/// Parse an RFC3339 UTC timestamp (`YYYY-MM-DDTHH:MM:SS[.mmm]Z`, also
/// `+00:00`). A3.0 triggers persist UTC only, so the parser rejects other
/// offsets instead of silently shifting them. Returns Unix milliseconds.
pub fn trigger_parse_rfc3339_ms(text : String) -> Int64? {
  let trimmed = text.trim().to_string()
  let length = trimmed.length()
  if length < 20 {
    return None
  }
  if trimmed.get_char(4) != Some('-') ||
    trimmed.get_char(7) != Some('-') ||
    trimmed.get_char(10) != Some('T') ||
    trimmed.get_char(13) != Some(':') ||
    trimmed.get_char(16) != Some(':') {
    return None
  }
  let year = match parse_fixed_int(trimmed, 0, 4) {
    Some(value) => value
    None => return None
  }
  let month = match parse_fixed_int(trimmed, 5, 2) {
    Some(value) => value
    None => return None
  }
  let day = match parse_fixed_int(trimmed, 8, 2) {
    Some(value) => value
    None => return None
  }
  let hour = match parse_fixed_int(trimmed, 11, 2) {
    Some(value) => value
    None => return None
  }
  let minute = match parse_fixed_int(trimmed, 14, 2) {
    Some(value) => value
    None => return None
  }
  let second = match parse_fixed_int(trimmed, 17, 2) {
    Some(value) => value
    None => return None
  }
  if month < 1 || month > 12 || day < 1 || day > 31 ||
    hour > 23 || minute > 59 || second > 59 {
    return None
  }
  let mut millis = 0
  let mut zone_index = 19
  if trimmed.get_char(19) == Some('.') {
    let fraction = match parse_fixed_int(trimmed, 20, 3) {
      Some(value) => value
      None => return None
    }
    millis = fraction
    zone_index = 23
  }
  if length != zone_index + 1 {
    return None
  }
  let zone = trimmed.get_char(zone_index)
  if zone != Some('Z') && zone != Some('z') {
    // Only UTC is accepted; a caller must normalize other offsets first.
    return None
  }
  let days = trigger_days_from_civil(year, month, day)
  Some(
    days * 86_400_000L +
    hour.to_int64() * 3_600_000L +
    minute.to_int64() * 60_000L +
    second.to_int64() * 1_000L +
    millis.to_int64(),
  )
}

///|
fn parse_fixed_int(text : String, start : Int, width : Int) -> Int? {
  if start + width > text.length() {
    return None
  }
  let piece = text.substring(start=start, end=start + width)
  let value = @string.parse_int(piece) catch { _ => return None }
  Some(value)
}

///|
fn trigger_days_from_civil(year : Int, month : Int, day : Int) -> Int64 {
  let y : Int64 = year.to_int64() -
    (if month <= 2 { 1L } else { 0L })
  let m : Int64 = month.to_int64() +
    (if month > 2 { -3L } else { 9L })
  // Howard Hinnant's civil calendar: 400-year eras, 146097 days per era.
  let era : Int64 = (if y >= 0L { y } else { y - 399L }) / 400L
  let yoe : Int64 = y - era * 400L
  let doy : Int64 = (153L * m + 2L) / 5L + day.to_int64() - 1L
  let doe : Int64 = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146_097L + doe - 719_468L
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

///|
pub fn trigger_type_known(kind : String) -> Bool {
  kind == TRIGGER_TYPE_EVENT ||
  kind == TRIGGER_TYPE_SCHEDULE ||
  kind == TRIGGER_TYPE_WEBHOOK
}

///|
/// A3.0 implements event triggers only; the type exists so the RPC can tell
/// "not enabled yet" (`unsupported`) apart from "unknown" (`invalid`).
pub fn trigger_type_wired(kind : String) -> Bool {
  kind == TRIGGER_TYPE_EVENT
}

///|
pub fn trigger_name_valid(name : String) -> Bool {
  if name == "" || name.length() > TRIGGER_NAME_MAX {
    return false
  }
  let first = match name.get_char(0) {
    Some(value) => value
    None => return false
  }
  if !((first >= 'a' && first <= 'z') || (first >= '0' && first <= '9')) {
    return false
  }
  for ch in name {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_' ||
      ch == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Agent id rule shared with `valid_agent_id` in the host.
pub fn trigger_agent_id_valid(agent_id : String) -> Bool {
  if agent_id == "" || agent_id.length() > 64 {
    return false
  }
  for ch in agent_id {
    let code = ch.to_int()
    let ok = (code >= 97 && code <= 122) ||
      (code >= 65 && code <= 90) ||
      (code >= 48 && code <= 57) ||
      code == 45 ||
      code == 46 ||
      code == 95
    if !ok {
      return false
    }
  }
  true
}

///|
/// Fields that must never appear in a trigger config: commands, environment,
/// machine/worktree selection, policy or approval switches, or secret values.
/// Unknown fields are ignored by the parser, so this guard runs on the raw
/// JSON *before* parsing (ADR-0014 §1.2, §5).
pub fn trigger_forbidden_config_field(key : String) -> Bool {
  let lower = key.to_lower()
  match lower {
    "command" | "argv" | "args" | "env" | "shell" | "machine_id" |
    "worktree_id" | "policy" | "approval" | "approvals" | "decision" |
    "run_id" | "task_id" | "secret" | "secret_path" | "secret_value" =>
      true
    _ => is_secret_key_name(key)
  }
}

///|
/// Recursively scan a config object for forbidden keys. Values are never
/// inspected as commands; a key name is enough to reject the shape.
pub fn trigger_config_has_forbidden_field(json : @json.Json) -> Bool {
  match json {
    @json.Json::Object(fields) =>
      {
        let mut found = false
        for key in fields.keys() {
          if trigger_forbidden_config_field(key) {
            found = true
          } else {
            match fields.get(key) {
              Some(value) =>
                if trigger_config_has_forbidden_field(value) {
                  found = true
                }
              None => ()
            }
          }
        }
        found
      }
    @json.Json::Array(items) => {
      let mut found = false
      for item in items {
        if trigger_config_has_forbidden_field(item) {
          found = true
        }
      }
      found
    }
    _ => false
  }
}

///|
/// Event type patterns: exact (`run.failed`) or a trailing `.*` only
/// (`run.*`). No other wildcard, regex or boolean expression is accepted.
pub fn trigger_event_type_valid(pattern : String) -> Bool {
  if pattern == "" || pattern.length() > 128 {
    return false
  }
  if pattern.has_suffix(".*") {
    let prefix = pattern.substring(start=0, end=pattern.length() - 2)
    if prefix == "" {
      return false
    }
    for ch in prefix {
      if ch == '*' || ch == '?' || ch == ' ' || ch == '\t' {
        return false
      }
    }
    return true
  }
  for ch in pattern {
    if ch == '*' || ch == '?' || ch == ' ' || ch == '\t' {
      return false
    }
  }
  true
}

///|
/// High-volume or meta events that never match a trigger, whatever the
/// configuration says (ADR-0014 §2.2).
pub fn trigger_event_type_blacklisted(event_type : String) -> Bool {
  match event_type {
    "host.heartbeat" | "audit.recorded" | "run.progress" | "run.heartbeat" |
    "agent.session.output" | "agent.session.updated" =>
      true
    _ => event_type.has_prefix("trigger.")
  }
}

///|
pub fn trigger_verify_is_subset(
  verify : Array[String],
  project_verify : Array[String],
) -> Bool {
  for item in verify {
    let mut found = false
    for allowed in project_verify {
      if item == allowed {
        found = true
      }
    }
    if !found {
      return false
    }
  }
  true
}

// ---------------------------------------------------------------------------
// Event matching
// ---------------------------------------------------------------------------

///|
pub(all) enum TriggerMatchDecision {
  TriggerMatch
  TriggerNoMatch
  TriggerIgnoreSelf
  TriggerCascadeDepth
} derive(Eq, Show, Debug)

///|
/// Transactional write outcome shared by the trigger store and the host.
/// `TriggerVersionConflict` and `TriggerNotFound` come from the update CAS;
/// `TriggerDisabled` / `TriggerExpired` are the re-check inside the fire
/// transaction (ADR-0014 §6.3).
pub(all) enum TriggerWriteOutcome {
  TriggerApplied
  TriggerVersionConflict
  TriggerNotFound
  TriggerDuplicate
  TriggerDisabled
  TriggerExpired
} derive(Eq, Show, Debug)

///|
pub fn trigger_write_created(outcome : TriggerWriteOutcome) -> Bool {
  outcome == TriggerApplied
}

///|
/// Bounded event matching (ADR-0014 §2.2, §2.4). Pure: the dispatcher passes
/// the event metadata and the origin it resolved for the event; the function
/// decides match / ignore / cascade-reject. No expression evaluation.
pub fn match_event_trigger(
  trigger_id : String,
  source : TriggerSource,
  event_type : String,
  subject : String,
  correlation_id : String,
  origin : TriggerOrigin?,
) -> TriggerMatchDecision {
  if trigger_event_type_blacklisted(event_type) {
    return TriggerNoMatch
  }
  if !trigger_event_type_matches(source.event_type, event_type) {
    return TriggerNoMatch
  }
  if source.subject_prefix != "" &&
    !subject.has_prefix(source.subject_prefix) {
    return TriggerNoMatch
  }
  if source.correlation_id != "" && correlation_id != source.correlation_id {
    return TriggerNoMatch
  }
  match origin {
    Some(value) => {
      if source.ignore_self && value.trigger_id == trigger_id {
        return TriggerIgnoreSelf
      }
      if value.depth >= TRIGGER_MAX_CASCADE_DEPTH {
        return TriggerCascadeDepth
      }
    }
    None => ()
  }
  TriggerMatch
}

///|
fn trigger_event_type_matches(pattern : String, event_type : String) -> Bool {
  if pattern.has_suffix(".*") {
    let prefix = pattern.substring(start=0, end=pattern.length() - 1)
    return event_type.has_prefix(prefix)
  }
  pattern == event_type
}

///|
/// Depth of a Task created from an event: root = 1, child = parent + 1.
pub fn trigger_next_depth(origin : TriggerOrigin?) -> Int {
  match origin {
    Some(value) => value.depth + 1
    None => 1
  }
}

///|
pub fn trigger_origin_root(origin : TriggerOrigin?, self_id : String) -> String {
  match origin {
    Some(value) =>
      if value.root_trigger_id != "" {
        value.root_trigger_id
      } else if value.trigger_id != "" {
        value.trigger_id
      } else {
        self_id
      }
    None => self_id
  }
}

// ---------------------------------------------------------------------------
// Template rendering and dedupe keys
// ---------------------------------------------------------------------------

///|
/// Render a bounded `{{name}}` template. Only keys present in `vars` are
/// substituted (declared fields only); unknown placeholders render empty.
/// Values are bounded per-field and the result is capped at `max_len`.
/// This is pure text substitution: no shell, no `$` evaluation, no recursion.
pub fn render_template(
  template : String,
  vars : Map[String, String],
  max_len : Int,
) -> String {
  let mut out = ""
  let length = template.length()
  let mut index = 0
  while index < length {
    let is_open = template.get_char(index) == Some('{') &&
      index + 1 < length &&
      template.get_char(index + 1) == Some('{')
    if is_open {
      let mut cursor = index + 2
      let mut close = -1
      while cursor + 1 < length {
        if template.get_char(cursor) == Some('}') &&
          template.get_char(cursor + 1) == Some('}') {
          close = cursor
          break
        }
        cursor = cursor + 1
      }
      if close >= 0 {
        let key = template.substring(start=index + 2, end=close)
        let value = match vars.get(key) {
          Some(found) =>
            if found.length() > TRIGGER_RENDER_VALUE_MAX {
              found.substring(start=0, end=TRIGGER_RENDER_VALUE_MAX)
            } else {
              found
            }
          None => ""
        }
        out = out + value
        index = close + 2
        continue
      }
    }
    match template.get_char(index) {
      Some(ch) => out = out + ch.to_string()
      None => ()
    }
    index = index + 1
  }
  if out.length() > max_len {
    out.substring(start=0, end=max_len)
  } else {
    out
  }
}

///|
pub fn trigger_event_fire_key(event_id : String) -> String {
  "event:" + event_id
}

///|
pub fn trigger_slot_fire_key(scheduled_for_ms : Int64) -> String {
  "slot:" + scheduled_for_ms.to_string()
}

///|
pub fn trigger_manual_fire_key(request_id : String) -> String {
  "manual:" + request_id
}

///|
/// Deterministic event idempotency key: the second line of defence behind
/// `trigger_fires UNIQUE(trigger_id, fire_key)` (ADR-0014 §2.3).
pub fn trigger_task_event_idempotency(
  trigger_id : String,
  fire_key : String,
) -> String {
  "trigger/" + trigger_id + "/" + fire_key + "/task"
}

///|
pub fn trigger_run_idempotency(trigger_id : String, fire_key : String) -> String {
  "trigger:" + trigger_id + ":" + fire_key
}

// ---------------------------------------------------------------------------
// Rate buckets
// ---------------------------------------------------------------------------

///|
/// Token bucket in milli-tokens so fractional refill is not lost. Pure state:
/// the host keeps one bucket per trigger and one global bucket, and passes
/// `now_ms` on every attempt. A restart resets the buckets (documented
/// residual risk, ADR-0014 §9).
pub(all) struct TriggerRateBucket {
  tokens_milli : Int64
  last_ms : Int64
}

///|
pub fn trigger_rate_bucket_new(now_ms : Int64, burst : Int) -> TriggerRateBucket {
  {
    tokens_milli: burst.to_int64() * 1_000L,
    last_ms: now_ms,
  }
}

///|
pub fn trigger_rate_take(
  bucket : TriggerRateBucket,
  now_ms : Int64,
  per_minute : Int,
  burst : Int,
) -> (TriggerRateBucket, Bool) {
  let capacity = burst.to_int64() * 1_000L
  let mut state = bucket
  if now_ms > state.last_ms {
    let elapsed = now_ms - state.last_ms
    // milli-tokens per minute = per_minute * 1000; per millisecond =
    // per_minute / 60.
    let refill = elapsed * per_minute.to_int64() / 60L
    let tokens = state.tokens_milli + refill
    state = {
      tokens_milli: if tokens > capacity { capacity } else { tokens },
      last_ms: now_ms,
    }
  } else if now_ms < state.last_ms {
    // Clock rollback: no refill, and re-anchor to the earlier clock so the
    // later forward jump cannot mint a burst of tokens.
    state = { ..state, last_ms: now_ms }
  }
  if state.tokens_milli >= 1_000L {
    ({ ..state, tokens_milli: state.tokens_milli - 1_000L }, true)
  } else {
    (state, false)
  }
}

// ---------------------------------------------------------------------------
// Canonical config hash
// ---------------------------------------------------------------------------

///|
/// SHA-256 over the canonical config JSON, prefixed `sha256:` like the policy
/// digests. Canonical form: sorted object keys, no whitespace, no secret
/// fields, UTF-8. The trigger record carries no secret values by design, so
/// the hash can be shown in audit events.
pub fn trigger_config_hash(
  name : String,
  kind : String,
  enabled : Bool,
  expires_at : String,
  target : TriggerTarget,
  source : TriggerSource,
) -> String {
  let config = json_object([
    ("enabled", json_bool(enabled)),
    ("expires_at", json_string(expires_at)),
    ("name", json_string(name)),
    ("source", source.to_json()),
    ("target", target.to_json()),
    ("type", json_string(kind)),
  ])
  "sha256:" + trigger_sha256_hex(trigger_canonical_json(config))
}

///|
/// Canonical JSON: sorted keys, JSON string escaping, no whitespace. Secret
/// looking keys are dropped defensively even though the typed config has
/// none.
pub fn trigger_canonical_json(json : @json.Json) -> String {
  match json {
    @json.Json::Object(fields) => {
      let keys : Array[String] = []
      for key in fields.keys() {
        if !trigger_forbidden_config_field(key) {
          keys.push(key)
        }
      }
      keys.sort_by(fn(left, right) { trigger_lex_compare(left, right) })
      let parts : Array[String] = []
      for key in keys {
        match fields.get(key) {
          Some(value) =>
            parts.push(
              trigger_canonical_quote(key) +
              ":" +
              trigger_canonical_json(value),
            )
          None => ()
        }
      }
      "{" + parts.join(",") + "}"
    }
    @json.Json::Array(items) => {
      let parts : Array[String] = []
      for item in items {
        parts.push(trigger_canonical_json(item))
      }
      "[" + parts.join(",") + "]"
    }
    @json.Json::String(value) => trigger_canonical_quote(value)
    @json.Json::Number(value, ..) => {
      let as_int = value.to_int64()
      if value == as_int.to_double() {
        as_int.to_string()
      } else {
        value.to_string()
      }
    }
    @json.Json::True => "true"
    @json.Json::False => "false"
    @json.Json::Null => "null"
  }
}

///|
/// Byte-lexicographic comparison. `Array::sort()` on `String` compares by
/// length first, which is not canonical JSON key order.
fn trigger_lex_compare(left : String, right : String) -> Int {
  let shorter = left.length().min(right.length())
  let mut index = 0
  while index < shorter {
    let left_code = match left.get_char(index) {
      Some(ch) => ch.to_int()
      None => 0
    }
    let right_code = match right.get_char(index) {
      Some(ch) => ch.to_int()
      None => 0
    }
    if left_code != right_code {
      return left_code - right_code
    }
    index = index + 1
  }
  left.length() - right.length()
}

///|
fn trigger_canonical_quote(text : String) -> String {
  let mut out = "\""
  for ch in text {
    match ch {
      '"' => out = out + "\\\""
      '\\' => out = out + "\\\\"
      '\n' => out = out + "\\n"
      '\r' => out = out + "\\r"
      '\t' => out = out + "\\t"
      _ =>
        if ch.to_int() < 32 {
          out = out + "\\u" + trigger_four_hex(ch.to_int())
        } else {
          out = out + ch.to_string()
        }
    }
  }
  out + "\""
}

///|
fn trigger_four_hex(value : Int) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  let mut shift = 12
  while shift >= 0 {
    let index = (value >> shift) & 15
    match digits.get_char(index) {
      Some(ch) => out = out + ch.to_string()
      None => out = out + "0"
    }
    shift = shift - 4
  }
  out
}

// ---------------------------------------------------------------------------
// SHA-256 (FIPS 180-4)
// ---------------------------------------------------------------------------

///|
/// SHA-256 over the UTF-8 encoding of a string, lowercase hex. Implemented in
/// contracts so the canonical config hash stays dependency-free; it mirrors
/// the policy core's implementation. Not used for password hashing.
fn trigger_sha256_hex(text : String) -> String {
  trigger_sha256_bytes_hex(@utf8.encode(text))
}

///|
fn trigger_rotr32(word : UInt32, n : Int) -> UInt32 {
  (word >> n) | (word << (32 - n))
}

///|
fn trigger_sha256_bytes_hex(input : Bytes) -> String {
  let src = input.to_fixedarray()
  let n = src.length()
  let total = ((n + 9 + 63) / 64) * 64
  let buf : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  for i in 0..<n {
    buf[i] = src[i]
  }
  buf[n] = b'\x80'
  let bit_len : Int64 = n.to_int64() * 8L
  for i in 0..<8 {
    let shift : Int = (7 - i) * 8
    buf[total - 8 + i] = ((bit_len >> shift) & 255L).to_byte()
  }
  let state : FixedArray[UInt32] = FixedArray::make(8, 0U)
  state[0] = 0x6a09e667U
  state[1] = 0xbb67ae85U
  state[2] = 0x3c6ef372U
  state[3] = 0xa54ff53aU
  state[4] = 0x510e527fU
  state[5] = 0x9b05688cU
  state[6] = 0x1f83d9abU
  state[7] = 0x5be0cd19U
  let mut offset = 0
  while offset < total {
    trigger_sha256_compress(state, buf, offset)
    offset = offset + 64
  }
  let mut hex = ""
  for i in 0..<8 {
    let word = state[i]
    hex = hex +
      ((word >> 24) & 255U).to_byte().to_hex() +
      ((word >> 16) & 255U).to_byte().to_hex() +
      ((word >> 8) & 255U).to_byte().to_hex() +
      (word & 255U).to_byte().to_hex()
  }
  hex
}

///|
fn trigger_sha256_compress(
  state : FixedArray[UInt32],
  block : FixedArray[Byte],
  offset : Int,
) -> Unit {
  let k : Array[UInt32] = [
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU,
    0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U,
    0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U,
    0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U,
    0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
    0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
    0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U,
    0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U, 0x1e376c08U,
    0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU,
    0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U,
  ]
  let w : FixedArray[UInt32] = FixedArray::make(64, 0U)
  for i in 0..<16 {
    let p = offset + i * 4
    w[i] = (block[p].to_uint() << 24) |
      (block[p + 1].to_uint() << 16) |
      (block[p + 2].to_uint() << 8) |
      block[p + 3].to_uint()
  }
  for i in 16..<64 {
    let x = w[i - 15]
    let y = w[i - 2]
    let s0 = trigger_rotr32(x, 7) ^ trigger_rotr32(x, 18) ^ (x >> 3)
    let s1 = trigger_rotr32(y, 17) ^ trigger_rotr32(y, 19) ^ (y >> 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  }
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut e = state[4]
  let mut f = state[5]
  let mut g = state[6]
  let mut h = state[7]
  for i in 0..<64 {
    let s1 = trigger_rotr32(e, 6) ^ trigger_rotr32(e, 11) ^
      trigger_rotr32(e, 25)
    let ch = (e & f) ^ ((e ^ 0xFFFFFFFFU) & g)
    let temp1 = h + s1 + ch + k[i] + w[i]
    let s0 = trigger_rotr32(a, 2) ^ trigger_rotr32(a, 13) ^
      trigger_rotr32(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let temp2 = s0 + maj
    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
  state[4] = state[4] + e
  state[5] = state[5] + f
  state[6] = state[6] + g
  state[7] = state[7] + h
}

// ---------------------------------------------------------------------------
// Audit payloads
// ---------------------------------------------------------------------------

///|
/// `trigger.created` payload. The full record snapshot lets
/// `reconcile_trigger_projection` rebuild the projection from the event log.
pub fn trigger_created_payload(record : TriggerRecord) -> @json.Json {
  json_object([
    ("trigger_id", json_string(record.id)),
    ("type", json_string(record.kind)),
    ("name", json_string(record.name)),
    ("config_hash", json_string(record.config_hash)),
    ("created_by", json_string(record.created_by)),
    ("version", json_int(record.version)),
    ("record", record.to_json()),
  ])
}

///|
pub fn trigger_updated_payload(
  record : TriggerRecord,
  changed : Array[String],
  actor : String,
) -> @json.Json {
  json_object([
    ("trigger_id", json_string(record.id)),
    ("version", json_int(record.version)),
    ("changed", json_string_array(changed)),
    ("created_by", json_string(actor)),
    ("config_hash", json_string(record.config_hash)),
    ("record", record.to_json()),
  ])
}

///|
pub fn trigger_disabled_payload(
  record : TriggerRecord,
  actor : String,
  reason : String,
) -> @json.Json {
  json_object([
    ("trigger_id", json_string(record.id)),
    ("actor", json_string(actor)),
    ("reason", json_string(redact_secrets(reason))),
    ("record", record.to_json()),
  ])
}

///|
pub fn trigger_expired_payload(record : TriggerRecord) -> @json.Json {
  json_object([
    ("trigger_id", json_string(record.id)),
    ("expires_at", json_string(record.expires_at)),
    ("record", record.to_json()),
  ])
}

///|
/// `trigger.fired` payload: the audit link set required by ADR-0014 §6.2
/// (source, fire key, event/key links, Task/Run, depth, coalesced).
pub fn trigger_fired_payload(
  fire : TriggerFire,
  record : TriggerRecord,
) -> @json.Json {
  json_object([
    ("trigger_id", json_string(fire.trigger_id)),
    ("source", json_string(fire.source)),
    ("fire_key", json_string(fire.fire_key)),
    ("event_id", json_string(fire.event_id)),
    ("scheduled_for_ms", json_int64(fire.scheduled_for_ms)),
    ("key_id", json_string(fire.key_id)),
    ("task_id", json_string(fire.task_id)),
    ("run_id", json_string(fire.run_id)),
    ("coalesced", json_bool(fire.coalesced)),
    ("depth", json_int(fire.depth)),
    ("record", record.to_json()),
  ])
}

///|
/// `trigger.rejected` payload. `detail` is redacted here so a caller cannot
/// leak a secret into the event log; no raw webhook body is ever included.
pub fn trigger_rejected_payload(
  trigger_id : String,
  source : String,
  reason : String,
  detail : String,
  event_id~ : String = "",
  delivery_id~ : String = "",
  suppressed_count~ : Int = 0,
) -> @json.Json {
  let entries : Array[(String, @json.Json)] = [
    ("trigger_id", json_string(trigger_id)),
    ("source", json_string(source)),
    ("reason", json_string(reason)),
    ("detail", json_string(redact_secrets(detail))),
  ]
  if event_id != "" {
    entries.push(("event_id", json_string(event_id)))
  }
  if delivery_id != "" {
    entries.push(("delivery_id", json_string(delivery_id)))
  }
  if suppressed_count > 0 {
    entries.push(("suppressed_count", json_int(suppressed_count)))
  }
  json_object(entries)
}

// ---------------------------------------------------------------------------
// RPC errors and param/result helpers
// ---------------------------------------------------------------------------

///|
pub fn trigger_error_label(kind : String) -> String {
  match kind {
    "invalid" => "InvalidRequest"
    "not_found" => "NotFound"
    "conflict" => "Conflict"
    "unsupported" => "Unsupported"
    "rate_limited" => "RateLimited"
    "unauthorized" => "Unauthorized"
    _ => "Internal"
  }
}

///|
/// Same shape as `workspace_error` (ERR_HOST + data.kind), with the trigger
/// kinds from ADR-0014 §7. Messages and detail are redacted before return.
pub fn trigger_error(
  kind : String,
  message : String,
  detail? : String,
) -> RpcError {
  let entries : Array[(String, @json.Json)] = [
    ("kind", json_string(kind)),
    ("reason", json_string(redact_secrets(message))),
  ]
  match detail {
    Some(value) =>
      if value.trim() != "" {
        entries.push(("detail", json_string(redact_secrets(value))))
      }
    None => ()
  }
  RpcError::new(
    ERR_HOST,
    trigger_error_label(kind) + ": " + redact_secrets(message),
    data=json_object(entries),
  )
}

///|
pub fn trigger_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "trigger_id") {
    Some(value) if value.trim() != "" => Ok(value)
    _ => Err("missing trigger_id")
  }
}

///|
pub fn trigger_create_params(
  client_request_id : String,
  name : String,
  kind : String,
  target : TriggerTarget,
  source : TriggerSource,
  enabled : Bool,
  expires_at : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("name", json_string(name)),
    ("type", json_string(kind)),
    ("target", target.to_json()),
    ("source", source.to_json()),
    ("enabled", json_bool(enabled)),
    ("expires_at", json_string(expires_at)),
  ])
}

///|
pub fn trigger_update_params(
  client_request_id : String,
  trigger_id : String,
  expected_version : Int,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("trigger_id", json_string(trigger_id)),
    ("expected_version", json_int(expected_version)),
  ])
}

///|
pub fn trigger_result(
  record : TriggerRecord,
  now_ms : Int64,
) -> @json.Json {
  json_object([("trigger", record.to_public_json(now_ms))])
}

///|
pub fn triggers_result(
  records : Array[TriggerRecord],
  now_ms : Int64,
) -> @json.Json {
  json_object([
    (
      "triggers",
      json_array(records.map(fn(record) { record.to_public_json(now_ms) })),
    ),
  ])
}

///|
pub fn trigger_get_result(
  record : TriggerRecord,
  fires : Array[TriggerFire],
  now_ms : Int64,
) -> @json.Json {
  json_object([
    ("trigger", record.to_public_json(now_ms)),
    ("recent_fires", json_array(fires.map(fn(fire) { fire.to_json() }))),
  ])
}

///|
pub fn trigger_fire_result(
  task_id : String,
  run_id : String,
  duplicate : Bool,
) -> @json.Json {
  json_object([
    ("task_id", json_string(task_id)),
    ("run_id", json_string(run_id)),
    ("duplicate", json_bool(duplicate)),
  ])
}

///|
pub fn parse_trigger_result(
  json : @json.Json,
) -> Result[TriggerRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("trigger result is not an object")
  }
  match object.get("trigger") {
    Some(value) =>
      match trigger_record_from_json(value) {
        Some(record) => Ok(record)
        None => Err("corrupt trigger record")
      }
    None => Err("trigger result has no trigger")
  }
}

///|
pub fn parse_trigger_list(
  json : @json.Json,
) -> Result[Array[TriggerRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("trigger.list result is not an object")
  }
  let items = match object.get("triggers") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("trigger.list result has no triggers array")
  }
  let out : Array[TriggerRecord] = []
  for item in items {
    match trigger_record_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("corrupt trigger record")
    }
  }
  Ok(out)
}
