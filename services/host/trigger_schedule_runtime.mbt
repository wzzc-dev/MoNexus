///|
/// Schedule trigger runtime (ADR-0014 §3, A3.1).
///
/// Timezone resolution is host-side because it touches tzdata. Everything
/// else (next slot, DST policy, jitter, missed analysis) is the pure contracts
/// code. The loop keeps its 1s cadence and never holds `HostState.mutex`
/// across a tzdata read.
///
/// Claim order is the ADR's: CAS `next_fire_at` by `(id, expected)` -> insert
/// `trigger_fires` with `slot:<scheduled_for_ms>` -> Task + `trigger.fired`,
/// all in one store transaction.

///|
struct TriggerTimezonePlan {
  zone : @time.Zone
  resolved_tz : String
}

// ---------------------------------------------------------------------------
// tzdata resolution
// ---------------------------------------------------------------------------

///|
fn trigger_tzdata_dir() -> String {
  match @env.get_env_var("MONEXUS_TZDATA_DIR") {
    Some(value) =>
      if value != "" {
        value
      } else {
        "/usr/share/zoneinfo"
      }
    None => "/usr/share/zoneinfo"
  }
}

///|
async fn trigger_schedule_load_zone(
  name : String,
) -> Result[@time.Zone, String] {
  if name == "UTC" {
    return Ok(@contracts.trigger_zone_utc())
  }
  if !@contracts.trigger_iana_name_valid(name) {
    return Err("invalid IANA timezone name: " + name)
  }
  let path = trigger_tzdata_dir() + "/" + name
  let data = @fs.read_file(path) catch {
    error =>
      return Err(
        "timezone data for " + name + " is not readable at " + path + ": " +
        error.to_string(),
      )
  }
  @contracts.trigger_zone_from_tzif(name, data.binary().exact_view())
}

///|
fn trigger_last_index_of(text : String, needle : String) -> Int {
  let length = text.length()
  let needle_length = needle.length()
  if needle_length == 0 || needle_length > length {
    return -1
  }
  let mut found = -1
  for index in 0..=(length - needle_length) {
    let mut matches = true
    for offset in 0..<needle_length {
      if text.get_char(index + offset) != needle.get_char(offset) {
        matches = false
        break
      }
    }
    if matches {
      found = index
    }
  }
  found
}

///|
/// Resolve the machine's local zone to a concrete IANA name. `/etc/localtime`
/// is a symlink into a zoneinfo tree on Linux and macOS; `TZ` is the fallback
/// for containers that copy the file. Never guesses UTC.
async fn trigger_local_iana_name() -> Result[String, String] {
  let real = @fs.realpath("/etc/localtime") catch { _ => "" }
  if real != "" {
    let marker = "/zoneinfo/"
    let index = trigger_last_index_of(real, marker)
    if index >= 0 {
      let name = real[index + marker.length():].to_owned()
      if @contracts.trigger_iana_name_valid(name) {
        return Ok(name)
      }
    }
    // Some systems copy the TZif file instead of linking it; a bare path is
    // not a trustworthy IANA name.
  }
  match @env.get_env_var("TZ") {
    Some(value) =>
      if value != "" && !value.has_prefix(":") &&
        @contracts.trigger_iana_name_valid(value) {
        Ok(value)
      } else {
        Err(
          "cannot resolve the host local timezone; set source.timezone explicitly",
        )
      }
    None =>
      Err(
        "cannot resolve the host local timezone; set source.timezone explicitly",
      )
  }
}

///|
/// Resolve a `source.timezone` string to a loaded zone plus the canonical
/// `resolved_tz` persisted on the trigger. `local` is frozen here and never
/// stored as `local` (ADR-0014 §3.2).
async fn trigger_schedule_resolve_timezone(
  text : String,
) -> Result[TriggerTimezonePlan, @contracts.RpcError] {
  let timezone = match @contracts.trigger_timezone_parse(text) {
    Ok(value) => value
    Err(message) => {
      return Err(trigger_unsupported(message))
    }
  }
  match timezone {
    @contracts.TriggerTimezone::Utc =>
      Ok(
        {
          zone: @contracts.trigger_zone_utc(),
          resolved_tz: "UTC",
        },
      )
    @contracts.TriggerTimezone::Fixed(offset_seconds~) => {
      let zone = match @contracts.trigger_zone_fixed(offset_seconds) {
        Ok(value) => value
        Err(message) => {
          return Err(trigger_unsupported(message))
        }
      }
      Ok(
        {
          zone,
          resolved_tz: @contracts.trigger_timezone_canonical(timezone),
        },
      )
    }
    @contracts.TriggerTimezone::Iana(name~) => {
      let zone = match trigger_schedule_load_zone(name) {
        Ok(value) => value
        Err(message) => {
          return Err(trigger_unsupported(message))
        }
      }
      Ok({ zone, resolved_tz: name })
    }
    @contracts.TriggerTimezone::Local => {
      let name = match trigger_local_iana_name() {
        Ok(value) => value
        Err(message) => {
          return Err(trigger_unsupported(message))
        }
      }
      let zone = match trigger_schedule_load_zone(name) {
        Ok(value) => value
        Err(message) => {
          return Err(trigger_unsupported(message))
        }
      }
      Ok({ zone, resolved_tz: name })
    }
  }
}

///|
/// Zone for an existing schedule record. `resolved_tz` is authoritative; a
/// missing value (pre-A3.1 row) falls back to the stored source string.
async fn trigger_schedule_record_zone(
  record : @contracts.TriggerRecord,
) -> Result[@time.Zone, String] {
  let resolved = if record.resolved_tz != "" {
    record.resolved_tz
  } else if record.source.timezone != "" {
    record.source.timezone
  } else {
    "UTC"
  }
  if resolved == "UTC" {
    return Ok(@contracts.trigger_zone_utc())
  }
  let timezone = match @contracts.trigger_timezone_parse(resolved) {
    Ok(value) => value
    Err(message) => {
      return Err(message)
    }
  }
  match timezone {
    @contracts.TriggerTimezone::Utc => Ok(@contracts.trigger_zone_utc())
    @contracts.TriggerTimezone::Fixed(offset_seconds~) =>
      @contracts.trigger_zone_fixed(offset_seconds)
    @contracts.TriggerTimezone::Iana(name~) => trigger_schedule_load_zone(name)
    @contracts.TriggerTimezone::Local => {
      let name = match trigger_local_iana_name() {
        Ok(value) => value
        Err(message) => {
          return Err(message)
        }
      }
      trigger_schedule_load_zone(name)
    }
  }
}

///|
/// Pre-resolve the timezone for `trigger.create` before taking the mutex.
/// `None` means "not a schedule" (or a malformed request that the locked
/// path will reject), so the caller can pass it straight through.
async fn trigger_schedule_plan_for_create(
  params : Map[String, @json.Json],
) -> Result[TriggerTimezonePlan?, @contracts.RpcError] {
  let kind = @contracts.string_field_or(
    params,
    "type",
    @contracts.TRIGGER_TYPE_EVENT,
  )
  if kind != @contracts.TRIGGER_TYPE_SCHEDULE {
    return Ok(None)
  }
  let source_json = match params.get("source") {
    Some(value) => value
    None => return Ok(None)
  }
  let source = match @contracts.trigger_source_from_json(source_json) {
    Some(value) => value
    None => return Ok(None)
  }
  let plan = match trigger_schedule_resolve_timezone(source.timezone) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(Some(plan))
}

///|
/// Pre-resolve the timezone for `trigger.update`. An unchanged timezone is
/// re-read from the frozen `resolved_tz`, never from `local`, so an update
/// cannot silently unfreeze the zone.
async fn trigger_schedule_plan_for_update(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[TriggerTimezonePlan?, @contracts.RpcError] {
  let trigger_id = match @contracts.trigger_id_param(params) {
    Ok(value) => value
    Err(_) => return Ok(None)
  }
  state.mutex.acquire()
  let current = state.store.get_trigger(trigger_id)
  state.mutex.release()
  let current = match current {
    Ok(Some(value)) => value
    _ => return Ok(None)
  }
  if current.kind != @contracts.TRIGGER_TYPE_SCHEDULE {
    return Ok(None)
  }
  let source = match params.get("source") {
    Some(json) =>
      match @contracts.trigger_source_from_json(json) {
        Some(value) => value
        None => return Ok(None)
      }
    None => current.source
  }
  let text = if current.resolved_tz != "" &&
    source.timezone == current.source.timezone {
    current.resolved_tz
  } else {
    source.timezone
  }
  let plan = match trigger_schedule_resolve_timezone(text) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  Ok(Some(plan))
}

// ---------------------------------------------------------------------------
// Pure-ish helpers
// ---------------------------------------------------------------------------

///|
fn trigger_schedule_anchor_ms(now_ms : Int64) -> Int64 {
  now_ms - now_ms % 60_000L
}

///|
fn trigger_schedule_spec(
  record : @contracts.TriggerRecord,
) -> Result[@contracts.TriggerScheduleSpec, String] {
  @contracts.schedule_parse(record.source)
}

///|
fn trigger_schedule_vars(
  record : @contracts.TriggerRecord,
  slot_ms : Int64,
  now_ms : Int64,
) -> Map[String, String] {
  let vars : Map[String, String] = Map(
    [
      ("trigger_id", record.id),
      ("source", @contracts.TRIGGER_SOURCE_SCHEDULE),
      ("scheduled_for", @contracts.format_rfc3339(slot_ms)),
      ("scheduled_for_ms", slot_ms.to_string()),
      ("fired_at", @contracts.format_rfc3339(now_ms)),
    ],
  )
  vars
}

///|
fn trigger_schedule_reject_locked(
  state : HostState,
  record_after : @contracts.TriggerRecord,
  expected_next_fire_at : String,
  new_next_fire_at : String,
  reason : String,
  detail : String,
  missed_count : Int,
  key_suffix : String,
) -> Result[Bool, String] {
  let payload = @contracts.trigger_rejected_payload(
    record_after.id,
    @contracts.TRIGGER_SOURCE_SCHEDULE,
    reason,
    trigger_short_detail(detail),
    missed_count=missed_count,
    next_fire_at=new_next_fire_at,
  )
  let event = trigger_envelope(
    state,
    @contracts.EVENT_TRIGGER_REJECTED,
    trigger_record_subject(record_after.id),
    payload,
    "",
    "",
    "trigger-reject/" + record_after.id + "/" + key_suffix + "/" + reason,
  )
  match state.store.record_trigger_schedule_reject_event(
    event,
    record_after,
    expected_next_fire_at,
    new_next_fire_at,
  ) {
    Ok(applied) => {
      if applied {
        state.publish(event)
      }
      Ok(applied)
    }
    Err(message) => Err(message)
  }
}

// ---------------------------------------------------------------------------
// One due slot (caller holds the mutex)
// ---------------------------------------------------------------------------

///|
fn trigger_schedule_process_locked(
  state : HostState,
  record : @contracts.TriggerRecord,
  zone : @time.Zone,
  now_ms : Int64,
) -> Result[Unit, String] {
  if record.kind != @contracts.TRIGGER_TYPE_SCHEDULE {
    return Ok(())
  }
  if !record.enabled {
    return Ok(())
  }
  if @contracts.trigger_is_expired_at(record.expires_at, now_ms) {
    return Ok(())
  }
  let spec = match trigger_schedule_spec(record) {
    Ok(value) => value
    Err(message) => {
      return Err("invalid schedule source: " + message)
    }
  }
  let anchor = if record.anchor_ms != 0L {
    record.anchor_ms
  } else {
    trigger_schedule_anchor_ms(now_ms)
  }
  // An empty `next_fire_at` can only come from a pre-A3.1 projection row.
  // Initialize the first future slot without creating a Task.
  if record.next_fire_at == "" {
    let next_ms = match @contracts.schedule_next_slot(
      spec,
      zone,
      anchor,
      now_ms,
    ) {
      Ok(value) => value
      Err(message) => {
        return Err(message)
      }
    }
    let timestamp = @contracts.format_rfc3339(now_ms)
    let updated = {
      ..record,
      anchor_ms: anchor,
      next_fire_at: @contracts.format_rfc3339(next_ms),
      updated_at: if record.updated_at == "" {
        timestamp
      } else {
        record.updated_at
      },
    }
    return state.store.refresh_trigger_projection(updated)
  }
  let slot_ms = match @contracts.trigger_parse_rfc3339_ms(
    record.next_fire_at,
  ) {
    Some(value) => value
    None => {
      return Ok(())
    }
  }
  if now_ms < slot_ms {
    return Ok(())
  }
  if !@contracts.schedule_is_due(spec, record.id, slot_ms, now_ms) {
    return Ok(())
  }
  let missed = match @contracts.schedule_missed(
    spec,
    zone,
    anchor,
    slot_ms,
    now_ms,
  ) {
    Ok(value) => value
    Err(message) => {
      return Err(message)
    }
  }
  let coalesce = spec.missed == "coalesce_once"
  let use_coalesce = missed.due_count > 1 && coalesce && !missed.too_old
  let target_slot = if use_coalesce {
    missed.latest_slot_ms
  } else {
    slot_ms
  }
  let next_ms = if missed.due_count > 1 {
    // Both missed policies jump straight to the first future slot.
    missed.next_slot_ms
  } else {
    match @contracts.schedule_next_slot(spec, zone, anchor, slot_ms) {
      Ok(value) => value
      Err(message) => {
        return Err(message)
      }
    }
  }
  let next_fire_at = @contracts.format_rfc3339(next_ms)
  // Missed policy wins over a normal fire: `skip`/too-old coalesce never
  // creates a Task, and coalesce creates exactly one for the latest slot.
  if missed.due_count > 1 {
    if use_coalesce {
      let vars = trigger_schedule_vars(record, target_slot, now_ms)
      let fire_key = @contracts.trigger_slot_fire_key(target_slot)
      let prepared = match trigger_prepare(
        state,
        record,
        @contracts.TRIGGER_SOURCE_SCHEDULE,
        fire_key,
        "",
        vars,
        1,
        record.id,
        "",
        state.host_id,
        now_ms,
        next_fire_at,
        target_slot,
        "",
        true,
      ) {
        Ok(value) => value
        Err(attempt) => {
          let record_after = { ..record, next_fire_at }
          match trigger_schedule_reject_locked(
            state,
            record_after,
            record.next_fire_at,
            next_fire_at,
            @contracts.TRIGGER_REJECT_INVALID_TARGET,
            attempt.detail,
            0,
            "slot/" + target_slot.to_string(),
          ) {
            Ok(_) => ()
            Err(message) => {
              return Err(message)
            }
          }
          return Ok(())
        }
      }
      match state.store.record_trigger_schedule_event(
        prepared.task_events,
        prepared.fired_event,
        prepared.task,
        prepared.fire,
        prepared.record_after,
        record.next_fire_at,
        next_fire_at,
        now_ms,
      ) {
        Ok(@contracts.TriggerApplied) => {
          for event in prepared.task_events {
            state.publish(event)
          }
          state.publish(prepared.fired_event)
          return Ok(())
        }
        Ok(@contracts.TriggerDuplicate) => return Ok(())
        Ok(@contracts.TriggerVersionConflict) => return Ok(())
        Ok(@contracts.TriggerDisabled) => return Ok(())
        Ok(@contracts.TriggerExpired) => return Ok(())
        Ok(@contracts.TriggerNotFound) => return Ok(())
        Err(message) => {
          return Err(message)
        }
      }
    }
    let missed_count = missed.due_count
    let record_after = { ..record, next_fire_at }
    let policy = if coalesce {
      "coalesce_once (older than retention)"
    } else {
      "skip"
    }
    let detail = "host missed " + missed_count.to_string() +
      " schedule slot(s); policy " + policy
    match trigger_schedule_reject_locked(
      state,
      record_after,
      record.next_fire_at,
      next_fire_at,
      @contracts.TRIGGER_REJECT_MISSED_WINDOW,
      detail,
      missed_count,
      "missed/" + slot_ms.to_string(),
    ) {
      Ok(_) => ()
      Err(message) => {
        return Err(message)
      }
    }
    return Ok(())
  }
  // Normal fire. The global rate guard is checked before the commit; a
  // rejected slot is advanced so the tick does not spin on it.
  if !trigger_global_rate_allow(state, now_ms) {
    let record_after = { ..record, next_fire_at }
    match trigger_schedule_reject_locked(
      state,
      record_after,
      record.next_fire_at,
      next_fire_at,
      @contracts.TRIGGER_REJECT_RATE_LIMITED,
      "global trigger rate limit reached",
      0,
      "rate/" + (now_ms / 60_000L).to_string(),
    ) {
      Ok(_) => ()
      Err(message) => {
        return Err(message)
      }
    }
    return Ok(())
  }
  let vars = trigger_schedule_vars(record, target_slot, now_ms)
  let fire_key = @contracts.trigger_slot_fire_key(target_slot)
  let prepared = match trigger_prepare(
    state,
    record,
    @contracts.TRIGGER_SOURCE_SCHEDULE,
    fire_key,
    "",
    vars,
    1,
    record.id,
    "",
    state.host_id,
    now_ms,
    next_fire_at,
    target_slot,
    "",
    false,
  ) {
    Ok(value) => value
    Err(attempt) => {
      let record_after = { ..record, next_fire_at }
      match trigger_schedule_reject_locked(
        state,
        record_after,
        record.next_fire_at,
        next_fire_at,
        @contracts.TRIGGER_REJECT_INVALID_TARGET,
        attempt.detail,
        0,
        "slot/" + target_slot.to_string(),
      ) {
        Ok(_) => ()
        Err(message) => {
          return Err(message)
        }
      }
      return Ok(())
    }
  }
  match state.store.record_trigger_schedule_event(
    prepared.task_events,
    prepared.fired_event,
    prepared.task,
    prepared.fire,
    prepared.record_after,
    record.next_fire_at,
    next_fire_at,
    now_ms,
  ) {
    Ok(@contracts.TriggerApplied) => {
      for event in prepared.task_events {
        state.publish(event)
      }
      state.publish(prepared.fired_event)
      Ok(())
    }
    Ok(@contracts.TriggerDuplicate) => Ok(())
    Ok(@contracts.TriggerVersionConflict) => Ok(())
    Ok(@contracts.TriggerDisabled) => Ok(())
    Ok(@contracts.TriggerExpired) => Ok(())
    Ok(@contracts.TriggerNotFound) => Ok(())
    Err(message) => Err(message)
  }
}

// ---------------------------------------------------------------------------
// Startup, skew and the 1s loop
// ---------------------------------------------------------------------------

///|
/// Apply the missed policy once to every schedule before the dispatcher
/// starts (ADR-0014 §3.4). A trigger that is not due is left untouched.
async fn trigger_schedule_startup(state : HostState) -> Result[Unit, String] {
  let now_ms = @async.now()
  state.mutex.acquire()
  let records = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      return Err(message)
    }
  }
  let _ = state.store.set_trigger_last_tick_ms(now_ms)
  state.mutex.release()
  for record in records {
    if record.kind != @contracts.TRIGGER_TYPE_SCHEDULE ||
      !record.enabled ||
      @contracts.trigger_is_expired_at(record.expires_at, now_ms) {
      continue
    }
    let zone = match trigger_schedule_record_zone(record) {
      Ok(value) => value
      Err(message) => {
        println(
          "monexus-host: schedule " + record.id +
          " skipped during startup: " + message,
        )
        continue
      }
    }
    state.mutex.acquire()
    let fresh = match state.store.get_trigger(record.id) {
      Ok(Some(value)) => value
      Ok(None) => {
        state.mutex.release()
        continue
      }
      Err(message) => {
        state.mutex.release()
        return Err(message)
      }
    }
    if fresh.kind == @contracts.TRIGGER_TYPE_SCHEDULE &&
      fresh.enabled &&
      fresh.next_fire_at != "" {
      let slot_ms = match @contracts.trigger_parse_rfc3339_ms(
        fresh.next_fire_at,
      ) {
        Some(value) => value
        None => 0L
      }
      if slot_ms >= now_ms {
        state.mutex.release()
        continue
      }
    }
    let outcome = trigger_schedule_process_locked(state, fresh, zone, now_ms)
    state.mutex.release()
    // Run creation waits until the task group exists (serve() calls
    // trigger_start_pending_runs after the group is installed); dispatching
    // here would leave a Run marked running with no executor.
    match outcome {
      Ok(_) => ()
      Err(message) =>
        println(
          "monexus-host: schedule startup pass failed for " + record.id + ": " +
          message,
        )
    }
  }
  Ok(())
}

///|
/// On a wall-clock rollback, clamp every active schedule to the first slot
/// after `now` and record one `clock_skew` rejection per trigger. The tzdata
/// reads happen with the mutex released.
async fn trigger_schedule_handle_clock_skew(
  state : HostState,
  now_ms : Int64,
) -> Result[Unit, String] {
  state.mutex.acquire()
  let records = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      return Err(message)
    }
  }
  state.mutex.release()
  for record in records {
    if record.kind != @contracts.TRIGGER_TYPE_SCHEDULE || !record.enabled {
      continue
    }
    let zone = match trigger_schedule_record_zone(record) {
      Ok(value) => value
      Err(_) => continue
    }
    state.mutex.acquire()
    let fresh = match state.store.get_trigger(record.id) {
      Ok(Some(value)) => value
      Ok(None) => {
        state.mutex.release()
        continue
      }
      Err(message) => {
        state.mutex.release()
        return Err(message)
      }
    }
    let outcome = trigger_schedule_apply_skew_clamp(state, fresh, zone, now_ms)
    state.mutex.release()
    match outcome {
      Ok(_) => ()
      Err(message) =>
        println(
          "monexus-host: clock skew clamp failed for " + record.id + ": " +
          message,
        )
    }
  }
  state.mutex.acquire()
  let _ = state.store.set_trigger_last_tick_ms(now_ms)
  state.mutex.release()
  Ok(())
}

///|
fn trigger_schedule_apply_skew_clamp(
  state : HostState,
  record : @contracts.TriggerRecord,
  zone : @time.Zone,
  now_ms : Int64,
) -> Result[Unit, String] {
  let spec = match trigger_schedule_spec(record) {
    Ok(value) => value
    Err(message) => {
      return Err(message)
    }
  }
  if record.next_fire_at == "" {
    return Ok(())
  }
  let anchor = if record.anchor_ms != 0L {
    record.anchor_ms
  } else {
    trigger_schedule_anchor_ms(now_ms)
  }
  let clamp_after = now_ms +
    @contracts.schedule_jitter_ms(record.id, now_ms, spec.jitter_s)
  let next_ms = match @contracts.schedule_next_slot(
    spec,
    zone,
    anchor,
    clamp_after,
  ) {
    Ok(value) => value
    Err(message) => {
      return Err(message)
    }
  }
  let next_fire_at = @contracts.format_rfc3339(next_ms)
  let record_after = { ..record, next_fire_at }
  match trigger_schedule_reject_locked(
    state,
    record_after,
    record.next_fire_at,
    next_fire_at,
    @contracts.TRIGGER_REJECT_CLOCK_SKEW,
    "wall clock moved back more than five minutes",
    0,
    "skew/" + now_ms.to_string(),
  ) {
    Ok(_) => Ok(())
    Err(message) => Err(message)
  }
}

///|
/// The only schedule dispatcher. One second between scans, at most 100 due
/// triggers per tick (ADR-0014 §3.3), plus nonce pruning.
async fn trigger_schedule_loop(state : HostState) -> Unit {
  for ;; {
    @async.sleep(@contracts.TRIGGER_SCHEDULE_TICK_MS)
    state.mutex.acquire()
    let now_ms = @async.now()
    let last_tick = match state.store.trigger_last_tick_ms() {
      Ok(Some(value)) => value
      Ok(None) => now_ms
      Err(message) => {
        println(
          "monexus-host: cannot read trigger tick watermark: " + message,
        )
        now_ms
      }
    }
    if @contracts.trigger_clock_skewed(now_ms, last_tick) {
      state.mutex.release()
      match trigger_schedule_handle_clock_skew(state, now_ms) {
        Ok(_) => ()
        Err(message) =>
          println(
            "monexus-host: clock skew handling failed: " + message,
          )
      }
      continue
    }
    let due = match state.store.list_due_schedules(
      now_ms,
      @contracts.TRIGGER_SCHEDULE_SCAN_LIMIT,
    ) {
      Ok(value) => value
      Err(message) => {
        state.mutex.release()
        println("monexus-host: cannot scan due schedules: " + message)
        continue
      }
    }
    match state.store.prune_webhook_nonces(now_ms) {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: cannot prune webhook nonces: " + message)
    }
    let _ = state.store.set_trigger_last_tick_ms(now_ms)
    state.mutex.release()
    for record in due {
      let zone = match trigger_schedule_record_zone(record) {
        Ok(value) => value
        Err(message) => {
          println(
            "monexus-host: schedule " + record.id +
            " has no usable timezone: " + message,
          )
          continue
        }
      }
      state.mutex.acquire()
      let fresh = match state.store.get_trigger(record.id) {
        Ok(Some(value)) => value
        Ok(None) => {
          state.mutex.release()
          continue
        }
        Err(message) => {
          state.mutex.release()
          println(
            "monexus-host: cannot re-read schedule " + record.id + ": " +
            message,
          )
          continue
        }
      }
      let outcome = trigger_schedule_process_locked(state, fresh, zone, now_ms)
      state.mutex.release()
      match outcome {
        Ok(_) => trigger_start_pending_runs_for_trigger(state, record.id)
        Err(message) =>
          println(
            "monexus-host: schedule " + record.id + " failed: " + message,
          )
      }
    }
  }
}
