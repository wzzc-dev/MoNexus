///|
/// Trigger RPC handlers and the event dispatcher (ADR-0014, A3.0).
///
/// The dispatcher is a host task next to `heartbeat_loop`. It polls the
/// existing `events` table through `MachineStore::load_events_since` with the
/// persisted cursor `meta.trigger.event_cursor`; it does not use the in-memory
/// ring and does not add a second event log.
///
/// A trigger can only create a Task. There is no command, argv, environment,
/// approval or policy field anywhere below, and no path from a payload to an
/// argument vector. Runs are not started in A3.0 (`start_run=true` is
/// answered with `unsupported`); the Task is created with the same event and
/// projection shape as `task.create`.

///|
const TRIGGER_LOOP_INTERVAL_MS : Int = 200

///|
const TRIGGER_RECENT_FIRES : Int = 20

///|
const TRIGGER_LIST_LIMIT_DEFAULT : Int = 50

///|
const TRIGGER_LIST_LIMIT_MAX : Int = 200

///|
const TRIGGER_RATE_GLOBAL_KEY : String = "__trigger_global__"

///|
const TRIGGER_DETAIL_MAX : Int = 300

// Attempt outcomes (also used as stable wire-ish detail values).
const TRIGGER_ATTEMPT_CREATED : String = "created"

///|
const TRIGGER_ATTEMPT_DUPLICATE : String = "duplicate"

///|
const TRIGGER_ATTEMPT_DISABLED : String = "disabled"

///|
const TRIGGER_ATTEMPT_EXPIRED : String = "expired"

///|
const TRIGGER_ATTEMPT_INVALID_TARGET : String = "invalid_target"

///|
const TRIGGER_ATTEMPT_NOT_FOUND : String = "not_found"

///|
struct TriggerAttempt {
  outcome : String
  task_id : String
  run_id : String
  detail : String
}

// ---------------------------------------------------------------------------
// Small error helpers
// ---------------------------------------------------------------------------

///|
fn trigger_invalid(message : String) -> @contracts.RpcError {
  @contracts.trigger_error("invalid", message)
}

///|
fn trigger_not_found(message : String) -> @contracts.RpcError {
  @contracts.trigger_error("not_found", message)
}

///|
fn trigger_conflict(message : String) -> @contracts.RpcError {
  @contracts.trigger_error("conflict", message)
}

///|
fn trigger_unsupported(message : String) -> @contracts.RpcError {
  @contracts.trigger_error("unsupported", message)
}

///|
fn trigger_rate_limited(message : String) -> @contracts.RpcError {
  @contracts.trigger_error("rate_limited", message)
}

///|
fn trigger_short_detail(text : String) -> String {
  let redacted = @contracts.redact_secrets(text)
  if redacted.length() > TRIGGER_DETAIL_MAX {
    redacted.substring(start=0, end=TRIGGER_DETAIL_MAX)
  } else {
    redacted
  }
}

// ---------------------------------------------------------------------------
// Envelope construction (trigger events carry deterministic idempotency keys)
// ---------------------------------------------------------------------------

///|
fn trigger_envelope(
  state : HostState,
  event_type : String,
  subject : String,
  payload : @json.Json,
  causation_id : String,
  correlation_id : String,
  idempotency_key : String,
) -> @contracts.EventEnvelope {
  let now = @async.now()
  let seq = state.next_seq
  state.next_seq = seq + 1L
  let correlation = if correlation_id == "" {
    state.host_id
  } else {
    correlation_id
  }
  @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", now),
    org_id=@contracts.ORG_LOCAL,
    event_type~,
    ts=@contracts.format_rfc3339(now),
    subject~,
    seq~,
    payload~,
    causation_id~,
    correlation_id=correlation,
    idempotency_key~,
  )
}

///|
fn trigger_record_subject(trigger_id : String) -> String {
  "trigger/" + trigger_id
}

// ---------------------------------------------------------------------------
// Validation (caller holds the mutex)
// ---------------------------------------------------------------------------

///|
fn trigger_normalize_expiry(
  text : String,
  now_ms : Int64,
  required_future : Bool,
) -> Result[String, @contracts.RpcError] {
  let trimmed = text.trim().to_string()
  if trimmed == "" {
    return Ok("")
  }
  match @contracts.trigger_parse_rfc3339_ms(trimmed) {
    Some(value) =>
      if required_future && value <= now_ms {
        Err(trigger_invalid("expires_at must be in the future"))
      } else {
        Ok(@contracts.format_rfc3339(value))
      }
    None => Err(trigger_invalid("expires_at must be an RFC3339 UTC timestamp"))
  }
}

///|
fn trigger_validate_source(
  source : @contracts.TriggerSource,
) -> Result[@contracts.TriggerSource, @contracts.RpcError] {
  if source.event_type == "" {
    return Err(trigger_invalid("source.event_type is required"))
  }
  if !@contracts.trigger_event_type_valid(source.event_type) {
    return Err(
      trigger_invalid(
        "source.event_type must be exact or a trailing .* prefix",
      ),
    )
  }
  if @contracts.trigger_event_type_blacklisted(source.event_type) {
    return Err(trigger_invalid("source.event_type is not matchable"))
  }
  if source.subject_prefix.length() > @contracts.TRIGGER_SUBJECT_PREFIX_MAX {
    return Err(trigger_invalid("source.subject_prefix is too long"))
  }
  if source.correlation_id.length() > @contracts.TRIGGER_CORRELATION_MAX {
    return Err(trigger_invalid("source.correlation_id is too long"))
  }
  // Schedule/webhook-only fields are rejected on an event trigger so an
  // owner cannot smuggle a schedule configuration into an event source.
  if source.schedule_kind != "" ||
    source.interval_minutes != 0 ||
    source.at != "" ||
    source.weekday != 0 ||
    source.jitter_s != 0 ||
    source.missed != "skip" ||
    source.allowed_cidrs.length() != 0 {
    return Err(
      trigger_invalid("source contains fields for another trigger type"),
    )
  }
  if source.timezone != "UTC" {
    return Err(
      trigger_invalid("source.timezone is only valid for schedule triggers"),
    )
  }
  for name in source.payload_fields {
    if name == "" || name.length() > 64 {
      return Err(trigger_invalid("source.payload_fields contains a bad name"))
    }
    for ch in name {
      let code = ch.to_int()
      let ok = (code >= 97 && code <= 122) ||
        (code >= 65 && code <= 90) ||
        (code >= 48 && code <= 57) ||
        code == 95 ||
        code == 45
      if !ok {
        return Err(
          trigger_invalid("source.payload_fields contains a bad name"),
        )
      }
    }
    if @contracts.trigger_forbidden_config_field(name) {
      return Err(
        trigger_invalid("source.payload_fields cannot name a secret field"),
      )
    }
  }
  Ok(source)
}

///|
fn trigger_validate_target(
  state : HostState,
  target : @contracts.TriggerTarget,
  agent_id_required : Bool,
) -> Result[@contracts.TriggerTarget, @contracts.RpcError] {
  let title = target.title_template.trim().to_string()
  if title == "" {
    return Err(trigger_invalid("target.title_template is required"))
  }
  if target.title_template.length() > @contracts.TRIGGER_TITLE_MAX {
    return Err(trigger_invalid("target.title_template is too long"))
  }
  if target.goal_template.length() > @contracts.TRIGGER_GOAL_MAX {
    return Err(trigger_invalid("target.goal_template is too long"))
  }
  if target.start_run {
    return Err(
      trigger_unsupported(
        "start_run is not wired in A3.0; the trigger creates a planned Task only",
      ),
    )
  }
  if target.agent_id != "" && !@contracts.trigger_agent_id_valid(target.agent_id) {
    return Err(trigger_invalid("target.agent_id is invalid"))
  }
  if agent_id_required && target.agent_id == "" {
    return Err(trigger_invalid("target.agent_id is required for start_run"))
  }
  if target.workspace_id != "" {
    match state.store.get_workspace(target.workspace_id) {
      Ok(Some(_)) => ()
      Ok(None) =>
        return Err(trigger_not_found("referenced workspace was not found"))
      Err(message) =>
        return Err(trigger_invalid("cannot read workspace: " + message))
    }
  }
  let mut verify = target.verify
  if target.project_id != "" {
    let project = match state.store.get_project(target.project_id) {
      Ok(Some(value)) => value
      Ok(None) => return Err(trigger_not_found("referenced project was not found"))
      Err(message) => return Err(trigger_invalid("cannot read project: " + message))
    }
    if verify.is_empty() {
      verify = project.verify
    } else if !@contracts.trigger_verify_is_subset(verify, project.verify) {
      return Err(
        trigger_invalid("target.verify must be a subset of project.verify"),
      )
    }
  } else if !verify.is_empty() {
    return Err(trigger_invalid("target.verify requires target.project_id"))
  }
  Ok({ ..target, verify })
}

///|
fn trigger_referenced_targets_ok(
  state : HostState,
  target : @contracts.TriggerTarget,
) -> Result[Unit, String] {
  if target.workspace_id != "" {
    match state.store.get_workspace(target.workspace_id) {
      Ok(Some(_)) => ()
      Ok(None) => return Err("workspace " + target.workspace_id + " is missing")
      Err(message) => return Err(message)
    }
  }
  if target.project_id != "" {
    match state.store.get_project(target.project_id) {
      Ok(Some(project)) =>
        if !target.verify.is_empty() &&
          !@contracts.trigger_verify_is_subset(target.verify, project.verify) {
          return Err("project verify no longer contains target.verify")
        }
      Ok(None) => return Err("project " + target.project_id + " is missing")
      Err(message) => return Err(message)
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

///|
fn trigger_rate_allow(
  state : HostState,
  trigger_id : String,
  now_ms : Int64,
) -> Bool {
  let per_trigger = match state.trigger_buckets.get(trigger_id) {
    Some(bucket) => bucket
    None => @contracts.trigger_rate_bucket_new(
      now_ms,
      @contracts.TRIGGER_EVENT_RATE_BURST,
    )
  }
  let (per_bucket, allowed) = @contracts.trigger_rate_take(
    per_trigger,
    now_ms,
    @contracts.TRIGGER_EVENT_RATE_PER_MIN,
    @contracts.TRIGGER_EVENT_RATE_BURST,
  )
  state.trigger_buckets.set(trigger_id, per_bucket)
  if !allowed {
    return false
  }
  let global = match state.trigger_buckets.get(TRIGGER_RATE_GLOBAL_KEY) {
    Some(bucket) => bucket
    None => @contracts.trigger_rate_bucket_new(
      now_ms,
      @contracts.TRIGGER_GLOBAL_RATE_BURST,
    )
  }
  let (global_bucket, global_allowed) = @contracts.trigger_rate_take(
    global,
    now_ms,
    @contracts.TRIGGER_GLOBAL_RATE_PER_MIN,
    @contracts.TRIGGER_GLOBAL_RATE_BURST,
  )
  state.trigger_buckets.set(TRIGGER_RATE_GLOBAL_KEY, global_bucket)
  global_allowed
}

// ---------------------------------------------------------------------------
// Rejection audit
// ---------------------------------------------------------------------------

///|
/// Write one `trigger.rejected` event. Dedupe drops are intentionally not
/// logged; every other non-fire path uses this helper. The idempotency key
/// embeds the cause so a crash/replay does not duplicate the rejection.
fn trigger_reject(
  state : HostState,
  trigger_id : String,
  source : String,
  reason : String,
  detail : String,
  event_id : String,
  key_suffix : String,
) -> Result[Unit, String] {
  let payload = @contracts.trigger_rejected_payload(
    trigger_id,
    source,
    reason,
    trigger_short_detail(detail),
    event_id~,
  )
  let event = trigger_envelope(
    state,
    @contracts.EVENT_TRIGGER_REJECTED,
    trigger_record_subject(trigger_id),
    payload,
    event_id,
    "",
    "trigger-reject/" + trigger_id + "/" +
    (if key_suffix == "" { event_id } else { key_suffix }) +
    "/" + reason,
  )
  match state.store.append_event(event) {
    Ok(inserted) => {
      if inserted {
        state.publish(event)
      }
      Ok(())
    }
    Err(message) => Err(message)
  }
}

// ---------------------------------------------------------------------------
// Task attempt (shared by the event dispatcher and trigger.fire)
// ---------------------------------------------------------------------------

///|
/// Render and commit one trigger attempt. The store transaction is the only
/// place that decides "exactly once"; everything before it is pure or a read.
fn trigger_attempt(
  state : HostState,
  record : @contracts.TriggerRecord,
  source : String,
  fire_key : String,
  event_id : String,
  vars : Map[String, String],
  depth : Int,
  root_trigger_id : String,
  causation_id : String,
  correlation_id : String,
  now_ms : Int64,
) -> Result[TriggerAttempt, String] {
  match trigger_referenced_targets_ok(state, record.target) {
    Ok(_) => ()
    Err(message) =>
      return Ok({
        outcome: TRIGGER_ATTEMPT_INVALID_TARGET,
        task_id: "",
        run_id: "",
        detail: message,
      })
  }
  let target = record.target
  let title = @contracts
    .render_template(target.title_template, vars, @contracts.TRIGGER_TITLE_MAX)
    .trim()
    .to_string()
  if title == "" {
    return Ok({
      outcome: TRIGGER_ATTEMPT_INVALID_TARGET,
      task_id: "",
      run_id: "",
      detail: "title_template rendered empty",
    })
  }
  let goal = @contracts.redact_secrets(
    @contracts.render_template(
      target.goal_template,
      vars,
      @contracts.TRIGGER_GOAL_MAX,
    ),
  )
  let safe_title = @contracts.redact_secrets(title)
  let timestamp = @contracts.format_rfc3339(now_ms)
  let origin = @contracts.TriggerOrigin::new(
    trigger_id=record.id,
    fire_key~,
    root_trigger_id~,
    depth~,
    source~,
  )
  let task = @contracts.TaskRecord::new(
    id=@contracts.new_id("tsk", now_ms),
    title=safe_title,
    goal~,
    parent_id="",
    project_id=target.project_id,
    agent_id=target.agent_id,
    workspace_id=target.workspace_id,
    verify=target.verify,
    created_at=timestamp,
    status=@contracts.TASK_STATUS_PLANNED,
    origin=Some(origin),
  )
  let task_events : Array[@contracts.EventEnvelope] = []
  let base_key = "trigger/" + record.id + "/" + fire_key
  let created_event = trigger_envelope(
    state,
    @contracts.EVENT_TASK_CREATED,
    task.id,
    task.to_json(),
    causation_id,
    correlation_id,
    base_key + "/task",
  )
  task_events.push(created_event)
  if task.agent_id != "" {
    let assigned_event = trigger_envelope(
      state,
      @contracts.EVENT_TASK_ASSIGNED,
      task.id,
      task.to_json(),
      causation_id,
      correlation_id,
      base_key + "/assigned",
    )
    task_events.push(assigned_event)
  }
  let fire = @contracts.TriggerFire::new(
    id=@contracts.new_id("trf", now_ms),
    trigger_id=record.id,
    source~,
    fire_key~,
    event_id~,
    task_id=task.id,
    depth~,
    created_at=timestamp,
  )
  let record_after = { ..record, last_fired_at: timestamp }
  let fired_event = trigger_envelope(
    state,
    @contracts.EVENT_TRIGGER_FIRED,
    trigger_record_subject(record.id),
    @contracts.trigger_fired_payload(fire, record_after),
    causation_id,
    correlation_id,
    base_key + "/fired",
  )
  match state.store.record_trigger_task_event(
    task_events,
    fired_event,
    task,
    fire,
    record_after,
    now_ms,
  ) {
    Ok(@contracts.TriggerApplied) => {
      for event in task_events {
        state.publish(event)
      }
      state.publish(fired_event)
      Ok({
        outcome: TRIGGER_ATTEMPT_CREATED,
        task_id: task.id,
        run_id: "",
        detail: "",
      })
    }
    Ok(@contracts.TriggerDuplicate) =>
      Ok({
        outcome: TRIGGER_ATTEMPT_DUPLICATE,
        task_id: task.id,
        run_id: "",
        detail: "",
      })
    Ok(@contracts.TriggerDisabled) =>
      Ok({
        outcome: TRIGGER_ATTEMPT_DISABLED,
        task_id: "",
        run_id: "",
        detail: "",
      })
    Ok(@contracts.TriggerExpired) =>
      Ok({
        outcome: TRIGGER_ATTEMPT_EXPIRED,
        task_id: "",
        run_id: "",
        detail: "",
      })
    Ok(@contracts.TriggerNotFound) =>
      Ok({
        outcome: TRIGGER_ATTEMPT_NOT_FOUND,
        task_id: "",
        run_id: "",
        detail: "",
      })
    Ok(@contracts.TriggerVersionConflict) =>
      Ok({
        outcome: TRIGGER_ATTEMPT_NOT_FOUND,
        task_id: "",
        run_id: "",
        detail: "",
      })
    Err(message) => Err(message)
  }
}

// ---------------------------------------------------------------------------
// Event dispatcher
// ---------------------------------------------------------------------------

///|
fn trigger_event_vars(
  event : @contracts.EventEnvelope,
  source : @contracts.TriggerSource,
) -> Map[String, String] {
  let vars : Map[String, String] = Map([
    ("event_type", event.event_type),
    ("event_subject", event.subject),
    ("event_id", event.id),
    ("event_seq", event.seq.to_string()),
    ("event_ts", event.ts),
    ("correlation_id", event.correlation_id),
  ])
  match @contracts.as_object(event.payload) {
    Some(payload) =>
      for name in source.payload_fields {
        match @contracts.string_field(payload, name) {
          Some(value) =>
            if value.length() > @contracts.TRIGGER_RENDER_VALUE_MAX {
              vars.set(
                name,
                value.substring(
                  start=0,
                  end=@contracts.TRIGGER_RENDER_VALUE_MAX,
                ),
              )
            } else {
              vars.set(name, value)
            }
          None => ()
        }
      }
    None => ()
  }
  vars
}

///|
/// Resolve the trigger provenance carried by an event. Task events carry
/// `origin` inline (TaskRecord); Run events resolve through `run.task_id`.
fn trigger_origin_for_event(
  state : HostState,
  event : @contracts.EventEnvelope,
) -> @contracts.TriggerOrigin? {
  match @contracts.as_object(event.payload) {
    Some(payload) =>
      match payload.get("origin") {
        Some(value) =>
          match @contracts.trigger_origin_from_json(value) {
            Some(origin) => return Some(origin)
            None => ()
          }
        None => ()
      }
    None => ()
  }
  if event.event_type.has_prefix("run.") {
    match @contracts.as_object(event.payload) {
      Some(payload) =>
        match @contracts.string_field(payload, "task_id") {
          Some(task_id) if task_id != "" =>
            match state.store.get_task(task_id) {
              Ok(Some(task)) =>
                match task.origin {
                  Some(origin) => return Some(origin)
                  None => ()
                }
              _ => ()
            }
          _ => ()
        }
      None => ()
    }
  }
  None
}

///|
fn trigger_expire_sweep(state : HostState, now_ms : Int64) -> Result[Unit, String] {
  let records = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  for record in records {
    if record.enabled &&
      record.expired_at == "" &&
      @contracts.trigger_is_expired_at(record.expires_at, now_ms) {
      let timestamp = @contracts.format_rfc3339(now_ms)
      let updated = { ..record, expired_at: timestamp, updated_at: timestamp }
      let event = trigger_envelope(
        state,
        @contracts.EVENT_TRIGGER_EXPIRED,
        trigger_record_subject(record.id),
        @contracts.trigger_expired_payload(updated),
        "",
        "",
        "trigger/" + record.id + "/expired/" + record.expires_at,
      )
      match state.store.record_trigger_expired_event(event, updated) {
        Ok(true) => state.publish(event)
        Ok(false) => ()
        Err(message) => return Err(message)
      }
    }
  }
  Ok(())
}

///|
/// Process one event under the mutex. Returns `false` when the batch must
/// stop before this event (store error), so the cursor is not advanced past
/// it; replay will retry and dedupe.
fn trigger_process_event(
  state : HostState,
  event : @contracts.EventEnvelope,
  now_ms : Int64,
) -> Result[Unit, String] {
  let records = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let origin = trigger_origin_for_event(state, event)
  for record in records {
    if record.kind != @contracts.TRIGGER_TYPE_EVENT {
      continue
    }
    if !@contracts.trigger_is_active_at(record, now_ms) {
      continue
    }
    if event.seq <= record.active_from_seq {
      continue
    }
    let decision = @contracts.match_event_trigger(
      record.id,
      record.source,
      event.event_type,
      event.subject,
      event.correlation_id,
      origin,
    )
    match decision {
      @contracts.TriggerNoMatch => continue
      @contracts.TriggerIgnoreSelf => continue
      @contracts.TriggerCascadeDepth => {
        let result = trigger_reject(
          state,
          record.id,
          @contracts.TRIGGER_SOURCE_EVENT,
          @contracts.TRIGGER_REJECT_CASCADE_DEPTH,
          "cascade depth reached at event " + event.id,
          event.id,
          "",
        )
        match result {
          Ok(_) => continue
          Err(message) => return Err(message)
        }
      }
      @contracts.TriggerMatch => ()
    }
    if !trigger_rate_allow(state, record.id, now_ms) {
      match trigger_reject(
        state,
        record.id,
        @contracts.TRIGGER_SOURCE_EVENT,
        @contracts.TRIGGER_REJECT_RATE_LIMITED,
        "trigger rate limit reached",
        event.id,
        "",
      ) {
        Ok(_) => continue
        Err(message) => return Err(message)
      }
    }
    let vars = trigger_event_vars(event, record.source)
    let fire_key = @contracts.trigger_event_fire_key(event.id)
    let root = @contracts.trigger_origin_root(origin, record.id)
    let depth = @contracts.trigger_next_depth(origin)
    let attempt = match trigger_attempt(
      state,
      record,
      @contracts.TRIGGER_SOURCE_EVENT,
      fire_key,
      event.id,
      vars,
      depth,
      root,
      event.id,
      event.correlation_id,
      now_ms,
    ) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    match attempt.outcome {
      TRIGGER_ATTEMPT_CREATED | TRIGGER_ATTEMPT_DUPLICATE => continue
      TRIGGER_ATTEMPT_DISABLED => {
        match trigger_reject(
          state,
          record.id,
          @contracts.TRIGGER_SOURCE_EVENT,
          @contracts.TRIGGER_REJECT_DISABLED,
          "trigger was disabled before commit",
          event.id,
          "",
        ) {
          Ok(_) => continue
          Err(message) => return Err(message)
        }
      }
      TRIGGER_ATTEMPT_EXPIRED => {
        match trigger_reject(
          state,
          record.id,
          @contracts.TRIGGER_SOURCE_EVENT,
          @contracts.TRIGGER_REJECT_EXPIRED,
          "trigger expired before commit",
          event.id,
          "",
        ) {
          Ok(_) => continue
          Err(message) => return Err(message)
        }
      }
      _ => {
        match trigger_reject(
          state,
          record.id,
          @contracts.TRIGGER_SOURCE_EVENT,
          @contracts.TRIGGER_REJECT_INVALID_TARGET,
          attempt.detail,
          event.id,
          "",
        ) {
          Ok(_) => continue
          Err(message) => return Err(message)
        }
      }
    }
  }
  Ok(())
}

///|
/// Background event dispatcher. The cursor is committed only after the batch
/// (and every Task in it) is durably written. A crash before the cursor write
/// replays the batch; `(trigger_id, fire_key)` dedupes it.
async fn trigger_loop(state : HostState) -> Unit {
  let mut cursor = match state.store.trigger_event_cursor() {
    Ok(Some(value)) => value
    Ok(None) => {
      let current = match state.store.last_seq() {
        Ok(value) => value
        Err(message) => {
          println("monexus-host: cannot read trigger cursor base: " + message)
          0L
        }
      }
      state.mutex.acquire()
      let _ = state.store.set_trigger_event_cursor(current)
      state.mutex.release()
      current
    }
    Err(message) => {
      println("monexus-host: cannot read trigger cursor: " + message)
      0L
    }
  }
  for ;; {
    @async.sleep(TRIGGER_LOOP_INTERVAL_MS)
    state.mutex.acquire()
    let now_ms = @async.now()
    match trigger_expire_sweep(state, now_ms) {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: trigger expire sweep failed: " + message)
    }
    let events = match state.store.load_events_since(cursor, @contracts.TRIGGER_EVENT_BATCH) {
      Ok(value) => value
      Err(message) => {
        println("monexus-host: trigger dispatcher cannot read events: " + message)
        []
      }
    }
    let mut processed = 0
    for event in events {
      match trigger_process_event(state, event, now_ms) {
        Ok(_) => {
          cursor = event.seq
          processed = processed + 1
        }
        Err(message) => {
          println(
            "monexus-host: trigger dispatcher stopped at seq " +
            event.seq.to_string() + ": " + message,
          )
          break
        }
      }
    }
    if processed > 0 {
      match state.store.set_trigger_event_cursor(cursor) {
        Ok(_) => ()
        Err(message) =>
          println("monexus-host: cannot persist trigger cursor: " + message)
      }
    }
    state.mutex.release()
  }
}

// ---------------------------------------------------------------------------
// RPC handlers
// ---------------------------------------------------------------------------

///|
fn trigger_public_error(
  kind : String,
  message : String,
) -> @contracts.RpcError {
  @contracts.trigger_error(kind, message)
}

///|
fn trigger_create_locked(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@contracts.TriggerRecord, @contracts.RpcError] {
  let name = @contracts.string_field_or(params, "name", "").trim().to_string()
  if !@contracts.trigger_name_valid(name) {
    return Err(
      trigger_invalid(
        "name must match [a-z0-9][a-z0-9_-]{0,63}",
      ),
    )
  }
  let kind = @contracts.string_field_or(
    params,
    "type",
    @contracts.TRIGGER_TYPE_EVENT,
  )
  if !@contracts.trigger_type_known(kind) {
    return Err(trigger_invalid("unknown trigger type: " + kind))
  }
  if !@contracts.trigger_type_wired(kind) {
    return Err(
      trigger_unsupported(
        "only event triggers are wired in A3.0; schedule and webhook are A3.1",
      ),
    )
  }
  let target_json = match params.get("target") {
    Some(value) => value
    None => return Err(trigger_invalid("missing target"))
  }
  let source_json = match params.get("source") {
    Some(value) => value
    None => return Err(trigger_invalid("missing source"))
  }
  if @contracts.trigger_config_has_forbidden_field(target_json) {
    return Err(
      trigger_invalid(
        "target contains a forbidden field (command/env/secret/policy/etc.)",
      ),
    )
  }
  if @contracts.trigger_config_has_forbidden_field(source_json) {
    return Err(
      trigger_invalid(
        "source contains a forbidden field (command/env/secret/policy/etc.)",
      ),
    )
  }
  let target = match @contracts.trigger_target_from_json(target_json) {
    Some(value) => value
    None => return Err(trigger_invalid("target must be an object"))
  }
  let source = match @contracts.trigger_source_from_json(source_json) {
    Some(value) => value
    None => return Err(trigger_invalid("source must be an object"))
  }
  let enabled = @contracts.bool_field_or(params, "enabled", true)
  let now_ms = @async.now()
  let target = match trigger_validate_target(state, target, false) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source = match trigger_validate_source(source) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let expires_at = match trigger_normalize_expiry(
    @contracts.string_field_or(params, "expires_at", ""),
    now_ms,
    enabled,
  ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let records = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid("cannot list triggers: " + message))
  }
  let mut active = 0
  for existing in records {
    if existing.name == name {
      return Err(trigger_conflict("trigger name already exists"))
    }
    if @contracts.trigger_is_active_at(existing, now_ms) {
      active = active + 1
    }
  }
  if active >= @contracts.TRIGGER_MAX_ACTIVE_DEFAULT {
    return Err(
      trigger_conflict(
        "active trigger limit reached (" +
        @contracts.TRIGGER_MAX_ACTIVE_DEFAULT.to_string() + ")",
      ),
    )
  }
  let timestamp = @contracts.format_rfc3339(now_ms)
  let config_hash = @contracts.trigger_config_hash(
    name,
    kind,
    enabled,
    expires_at,
    target,
    source,
  )
  let record = @contracts.TriggerRecord::new(
    id=@contracts.new_id("trg", now_ms),
    org_id=@contracts.ORG_LOCAL,
    name~,
    kind~,
    target~,
    source~,
    config_hash~,
    created_by="owner",
    created_at=timestamp,
    active_from_seq=state.next_seq - 1L,
    enabled~,
    expires_at~,
  )
  let event = trigger_envelope(
    state,
    @contracts.EVENT_TRIGGER_CREATED,
    trigger_record_subject(record.id),
    @contracts.trigger_created_payload(record),
    "",
    "",
    "trigger/" + record.id + "/created",
  )
  match state.store.record_trigger_event(event, record) {
    Ok(_) => {
      state.publish(event)
      Ok(record)
    }
    Err(message) => Err(trigger_conflict("cannot persist trigger: " + message))
  }
}

///|
fn trigger_update_locked(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@contracts.TriggerRecord, @contracts.RpcError] {
  let trigger_id = match @contracts.trigger_id_param(params) {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid(message))
  }
  let expected_version = match @contracts.int_field(params, "expected_version") {
    Some(value) if value > 0 => value
    _ => return Err(trigger_invalid("expected_version must be a positive integer"))
  }
  let current = match state.store.get_trigger(trigger_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err(trigger_not_found("trigger not found"))
    Err(message) => return Err(trigger_invalid("cannot read trigger: " + message))
  }
  match params.get("type") {
    Some(kind_json) =>
      match @contracts.as_string(kind_json) {
        Some(value) =>
          if value != current.kind {
            return Err(trigger_invalid("trigger type is immutable"))
          }
        None => return Err(trigger_invalid("trigger type is immutable"))
      }
    None => ()
  }
  let now_ms = @async.now()
  let name = match @contracts.string_field(params, "name") {
    Some(value) => value.trim().to_string()
    None => current.name
  }
  if !@contracts.trigger_name_valid(name) {
    return Err(trigger_invalid("name must match [a-z0-9][a-z0-9_-]{0,63}"))
  }
  let target = match params.get("target") {
    Some(value) => {
      if @contracts.trigger_config_has_forbidden_field(value) {
        return Err(trigger_invalid("target contains a forbidden field"))
      }
      match @contracts.trigger_target_from_json(value) {
        Some(parsed) => parsed
        None => return Err(trigger_invalid("target must be an object"))
      }
    }
    None => current.target
  }
  let source = match params.get("source") {
    Some(value) => {
      if @contracts.trigger_config_has_forbidden_field(value) {
        return Err(trigger_invalid("source contains a forbidden field"))
      }
      match @contracts.trigger_source_from_json(value) {
        Some(parsed) => parsed
        None => return Err(trigger_invalid("source must be an object"))
      }
    }
    None => current.source
  }
  let enabled = @contracts.bool_field_or(params, "enabled", current.enabled)
  let target = match trigger_validate_target(state, target, false) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let source = match trigger_validate_source(source) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let expires_at = match params.get("expires_at") {
    Some(value) =>
      match @contracts.as_string(value) {
        Some(text) =>
          match trigger_normalize_expiry(text, now_ms, enabled) {
            Ok(normalized) => normalized
            Err(error) => return Err(error)
          }
        None => return Err(trigger_invalid("expires_at must be a string"))
      }
    None => current.expires_at
  }
  if enabled &&
    expires_at != "" &&
    @contracts.trigger_is_expired_at(expires_at, now_ms) {
    return Err(trigger_invalid("enabled trigger cannot have a past expires_at"))
  }
  let records = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid("cannot list triggers: " + message))
  }
  for existing in records {
    if existing.id != current.id && existing.name == name {
      return Err(trigger_conflict("trigger name already exists"))
    }
  }
  let changed : Array[String] = []
  if name != current.name {
    changed.push("name")
  }
  if enabled != current.enabled {
    changed.push("enabled")
  }
  if expires_at != current.expires_at {
    changed.push("expires_at")
  }
  if target.to_json().stringify() != current.target.to_json().stringify() {
    changed.push("target")
  }
  if source.to_json().stringify() != current.source.to_json().stringify() {
    changed.push("source")
  }
  let timestamp = @contracts.format_rfc3339(now_ms)
  let re_enabled = !current.enabled && enabled
  let active_from_seq = if re_enabled {
    state.next_seq - 1L
  } else {
    current.active_from_seq
  }
  // A successful re-enable clears the once-only expiry marker so a later
  // expiry can emit `trigger.expired` again.
  let expired_at = if re_enabled { "" } else { current.expired_at }
  let config_hash = @contracts.trigger_config_hash(
    name,
    current.kind,
    enabled,
    expires_at,
    target,
    source,
  )
  let updated = {
    ..current,
    name,
    enabled,
    expires_at,
    target,
    source,
    version: current.version + 1,
    config_hash,
    updated_at: timestamp,
    active_from_seq,
    expired_at,
  }
  let event = trigger_envelope(
    state,
    @contracts.EVENT_TRIGGER_UPDATED,
    trigger_record_subject(updated.id),
    @contracts.trigger_updated_payload(updated, changed, "owner"),
    "",
    "",
    "trigger/" + updated.id + "/updated/" + updated.version.to_string(),
  )
  match state.store.record_trigger_update_event(
    event,
    updated,
    expected_version,
  ) {
    Ok(@contracts.TriggerApplied) => {
      state.publish(event)
      Ok(updated)
    }
    Ok(@contracts.TriggerVersionConflict) =>
      Err(trigger_conflict("trigger version conflict"))
    Ok(@contracts.TriggerNotFound) => Err(trigger_not_found("trigger not found"))
    Ok(outcome) =>
      Err(trigger_conflict("trigger update was rejected"))
    Err(message) => Err(trigger_conflict("cannot persist trigger: " + message))
  }
}

///|
fn trigger_disable_locked(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@contracts.TriggerRecord, @contracts.RpcError] {
  let trigger_id = match @contracts.trigger_id_param(params) {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid(message))
  }
  let current = match state.store.get_trigger(trigger_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err(trigger_not_found("trigger not found"))
    Err(message) => return Err(trigger_invalid("cannot read trigger: " + message))
  }
  if !current.enabled {
    return Ok(current)
  }
  let now_ms = @async.now()
  let timestamp = @contracts.format_rfc3339(now_ms)
  let updated = {
    ..current,
    enabled: false,
    version: current.version + 1,
    updated_at: timestamp,
  }
  let event = trigger_envelope(
    state,
    @contracts.EVENT_TRIGGER_DISABLED,
    trigger_record_subject(updated.id),
    @contracts.trigger_disabled_payload(updated, "owner", "owner request"),
    "",
    "",
    "trigger/" + updated.id + "/disabled/" + updated.version.to_string(),
  )
  match state.store.record_trigger_event(event, updated) {
    Ok(_) => {
      state.publish(event)
      Ok(updated)
    }
    Err(message) => Err(trigger_conflict("cannot persist trigger: " + message))
  }
}

///|
fn trigger_list_locked(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[Array[@contracts.TriggerRecord], @contracts.RpcError] {
  let state_filter = @contracts.string_field_or(params, "state", "")
  if state_filter != "" &&
    state_filter != @contracts.TRIGGER_STATE_ACTIVE &&
    state_filter != @contracts.TRIGGER_STATE_DISABLED &&
    state_filter != @contracts.TRIGGER_STATE_EXPIRED {
    return Err(trigger_invalid("unknown trigger state filter"))
  }
  let type_filter = @contracts.string_field_or(params, "type", "")
  if type_filter != "" && !@contracts.trigger_type_known(type_filter) {
    return Err(trigger_invalid("unknown trigger type filter"))
  }
  let limit = @contracts.int_field_or(
    params,
    "limit",
    TRIGGER_LIST_LIMIT_DEFAULT,
  ).max(0).min(TRIGGER_LIST_LIMIT_MAX)
  let now_ms = @async.now()
  let records = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid("cannot list triggers: " + message))
  }
  let out : Array[@contracts.TriggerRecord] = []
  for record in records {
    if out.length() >= limit {
      break
    }
    if type_filter != "" && record.kind != type_filter {
      continue
    }
    if state_filter != "" &&
      @contracts.trigger_state_of(record, now_ms) != state_filter {
      continue
    }
    out.push(record)
  }
  Ok(out)
}

///|
fn trigger_get_locked(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[@json.Json, @contracts.RpcError] {
  let trigger_id = match @contracts.trigger_id_param(params) {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid(message))
  }
  let record = match state.store.get_trigger(trigger_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err(trigger_not_found("trigger not found"))
    Err(message) => return Err(trigger_invalid("cannot read trigger: " + message))
  }
  let fires = match state.store.get_trigger_fires(trigger_id, TRIGGER_RECENT_FIRES) {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid("cannot read trigger fires: " + message))
  }
  Ok(@contracts.trigger_get_result(record, fires, @async.now()))
}

///|
/// Manual test channel (ADR-0014 §7). It still goes through the same target
/// validation, rate limits and dedupe transaction; it never executes a
/// command or answers a Decision.
fn trigger_fire_locked(
  state : HostState,
  params : Map[String, @json.Json],
  client_request_id : String,
) -> Result[TriggerAttempt, @contracts.RpcError] {
  let trigger_id = match @contracts.trigger_id_param(params) {
    Ok(value) => value
    Err(message) => return Err(trigger_invalid(message))
  }
  let record = match state.store.get_trigger(trigger_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err(trigger_not_found("trigger not found"))
    Err(message) => return Err(trigger_invalid("cannot read trigger: " + message))
  }
  let now_ms = @async.now()
  if !record.enabled {
    return Err(trigger_conflict("trigger is disabled"))
  }
  if @contracts.trigger_is_expired_at(record.expires_at, now_ms) {
    return Err(trigger_conflict("trigger is expired"))
  }
  if !trigger_rate_allow(state, record.id, now_ms) {
    return Err(trigger_rate_limited("trigger rate limit reached"))
  }
  let note = @contracts.string_field_or(params, "note", "")
  let vars : Map[String, String] = Map([
    ("event_type", @contracts.TRIGGER_SOURCE_MANUAL),
    ("event_subject", trigger_record_subject(record.id)),
    ("event_id", ""),
    ("event_seq", ""),
    ("event_ts", @contracts.format_rfc3339(now_ms)),
    ("correlation_id", state.host_id),
    ("note", note),
  ])
  let fire_key = @contracts.trigger_manual_fire_key(client_request_id)
  let attempt = match trigger_attempt(
    state,
    record,
    @contracts.TRIGGER_SOURCE_MANUAL,
    fire_key,
    "",
    vars,
    1,
    record.id,
    "",
    state.host_id,
    now_ms,
  ) {
    Ok(value) => value
    Err(message) => return Err(trigger_conflict("cannot fire trigger: " + message))
  }
  match attempt.outcome {
    TRIGGER_ATTEMPT_CREATED => Ok(attempt)
    TRIGGER_ATTEMPT_DUPLICATE => {
      // The ledger already has this manual fire; return the original Task.
      match state.store.get_trigger_fire_row(record.id, fire_key) {
        Ok(existing) =>
          if existing.id != "" {
            Ok({
              outcome: attempt.outcome,
              task_id: existing.task_id,
              run_id: existing.run_id,
              detail: "",
            })
          } else {
            Ok(attempt)
          }
        Err(message) => Err(trigger_conflict("cannot read trigger fire: " + message))
      }
    }
    TRIGGER_ATTEMPT_DISABLED => Err(trigger_conflict("trigger is disabled"))
    TRIGGER_ATTEMPT_EXPIRED => Err(trigger_conflict("trigger is expired"))
    TRIGGER_ATTEMPT_INVALID_TARGET =>
      Err(trigger_conflict("invalid trigger target: " + attempt.detail))
    _ => Err(trigger_not_found("trigger not found"))
  }
}

///|
/// Entry point for every registered `trigger.*` method. The feature flag is
/// checked here: with `trigger.enabled=false` every trigger method returns
/// `unsupported` and no dispatcher exists, leaving the rest of the host
/// byte-identical to a build without A3.
async fn handle_trigger_rpc(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  if !state.trigger_enabled {
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      trigger_unsupported("triggers are disabled (trigger.enabled=false)"),
    )
    return
  }
  match request.method {
    @contracts.METHOD_TRIGGER_CREATE => {
      state.mutex.acquire()
      let outcome = trigger_create_locked(state, request.params)
      state.mutex.release()
      match outcome {
        Ok(record) =>
          send_machine_result(
            state,
            sink,
            request,
            client_request_id,
            @contracts.trigger_result(record, @async.now()),
          )
        Err(error) => send_machine_error(state, sink, request, client_request_id, error)
      }
    }
    @contracts.METHOD_TRIGGER_LIST => {
      state.mutex.acquire()
      let outcome = trigger_list_locked(state, request.params)
      state.mutex.release()
      match outcome {
        Ok(records) =>
          send_machine_result(
            state,
            sink,
            request,
            client_request_id,
            @contracts.triggers_result(records, @async.now()),
          )
        Err(error) => send_machine_error(state, sink, request, client_request_id, error)
      }
    }
    @contracts.METHOD_TRIGGER_GET => {
      state.mutex.acquire()
      let outcome = trigger_get_locked(state, request.params)
      state.mutex.release()
      match outcome {
        Ok(result) =>
          send_machine_result(state, sink, request, client_request_id, result)
        Err(error) => send_machine_error(state, sink, request, client_request_id, error)
      }
    }
    @contracts.METHOD_TRIGGER_UPDATE => {
      state.mutex.acquire()
      let outcome = trigger_update_locked(state, request.params)
      state.mutex.release()
      match outcome {
        Ok(record) =>
          send_machine_result(
            state,
            sink,
            request,
            client_request_id,
            @contracts.trigger_result(record, @async.now()),
          )
        Err(error) => send_machine_error(state, sink, request, client_request_id, error)
      }
    }
    @contracts.METHOD_TRIGGER_DISABLE => {
      state.mutex.acquire()
      let outcome = trigger_disable_locked(state, request.params)
      state.mutex.release()
      match outcome {
        Ok(record) =>
          send_machine_result(
            state,
            sink,
            request,
            client_request_id,
            @contracts.trigger_result(record, @async.now()),
          )
        Err(error) => send_machine_error(state, sink, request, client_request_id, error)
      }
    }
    @contracts.METHOD_TRIGGER_FIRE => {
      state.mutex.acquire()
      let outcome = trigger_fire_locked(state, request.params, client_request_id)
      state.mutex.release()
      match outcome {
        Ok(attempt) =>
          send_machine_result(
            state,
            sink,
            request,
            client_request_id,
            @contracts.trigger_fire_result(
              attempt.task_id,
              attempt.run_id,
              attempt.outcome == TRIGGER_ATTEMPT_DUPLICATE,
            ),
          )
        Err(error) => send_machine_error(state, sink, request, client_request_id, error)
      }
    }
    _ =>
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        trigger_unsupported(
          request.method + " is not implemented until A3.1",
        ),
      )
  }
}
