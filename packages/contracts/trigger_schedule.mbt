///|
/// Schedule trigger contracts (ADR-0014 §3, A3.1).
///
/// Everything here is pure: `schedule_next_slot`, `schedule_is_due` and
/// `schedule_missed` take an already-resolved `@time.Zone` and an explicit
/// `now_ms`, so DST, missed windows and jitter can be tested without sleeping.
/// Reading tzdata and fixing the anchor at creation belong to the host.

///|
pub const TRIGGER_SCHEDULE_KIND_EVERY : String = "every"

///|
pub const TRIGGER_SCHEDULE_KIND_DAILY : String = "daily"

///|
pub const TRIGGER_SCHEDULE_KIND_WEEKLY : String = "weekly"

///|
pub const TRIGGER_SCHEDULE_INTERVAL_MIN : Int = 1

///|
pub const TRIGGER_SCHEDULE_INTERVAL_MAX : Int = 1_440

///|
pub const TRIGGER_SCHEDULE_JITTER_MAX_S : Int = 300

///|
/// Slots older than this are never replayed by `coalesce_once` (§3.4). It
/// matches the dedupe ledger retention in §6.1.
pub const TRIGGER_SLOT_RETENTION_DAYS : Int = 90

///|
pub const TRIGGER_SCHEDULE_SCAN_LIMIT : Int = 100

///|
pub const TRIGGER_SCHEDULE_TICK_MS : Int = 1_000

///|
/// A wall clock more than five minutes behind the persisted tick is treated
/// as a rollback, not as a reason to replay slots (§3.4).
pub const TRIGGER_CLOCK_SKEW_MS : Int64 = 300_000

///|
/// Parsed, validated schedule configuration. The anchor and resolved timezone
/// live on `TriggerRecord`, not in the source, because they are frozen at
/// creation and must survive updates that do not touch the schedule.
pub(all) struct TriggerScheduleSpec {
  kind : String
  interval_minutes : Int
  at_hour : Int
  at_minute : Int
  weekday : Int
  jitter_s : Int
  missed : String
}

///|
pub fn TriggerScheduleSpec::new(
  kind~ : String,
  interval_minutes~ : Int = 0,
  at_hour~ : Int = 0,
  at_minute~ : Int = 0,
  weekday~ : Int = 0,
  jitter_s~ : Int = 0,
  missed~ : String = "skip",
) -> TriggerScheduleSpec {
  { kind, interval_minutes, at_hour, at_minute, weekday, jitter_s, missed }
}

///|
/// A timezone string from `source.timezone`, classified but not yet loaded.
/// `Iana` must be read from `$MONEXUS_TZDATA_DIR` (or `/usr/share/zoneinfo`)
/// by the host; `Local` is resolved once at creation and then frozen.
#derive(Eq, Debug)
pub(all) enum TriggerTimezone {
  Utc
  Fixed(offset_seconds~ : Int)
  Iana(name~ : String)
  Local
}

///|
/// `""` means the omitted default and is UTC. Unknown or malformed names are
/// rejected here; the caller maps this failure to `unsupported`, never to a
/// silent UTC fallback (ADR-0014 §3.2).
pub fn trigger_timezone_parse(text : String) -> Result[TriggerTimezone, String] {
  let value = text.trim().to_owned()
  if value == "" || value == "UTC" {
    return Ok(Utc)
  }
  if value == "local" {
    return Ok(Local)
  }
  if value.length() == 6 &&
    (value.get_char(0) == Some('+') || value.get_char(0) == Some('-')) &&
    value.get_char(3) == Some(':') {
    let hours = trigger_two_digits(value, 1)
    let minutes = trigger_two_digits(value, 4)
    match (hours, minutes) {
      (Some(h), Some(m)) => {
        if m > 59 {
          return Err("timezone offset minutes must be 00..59")
        }
        let mut seconds = h * 3600 + m * 60
        if value.get_char(0) == Some('-') {
          seconds = -seconds
        }
        // -12:00 .. +14:00 inclusive.
        if seconds < -12 * 3600 || seconds > 14 * 3600 {
          return Err("timezone offset must be within -12:00..+14:00")
        }
        return Ok(Fixed(offset_seconds=seconds))
      }
      _ => return Err("timezone offset must be +HH:MM or -HH:MM")
    }
  }
  if trigger_iana_name_valid(value) {
    return Ok(Iana(name=value))
  }
  Err(
    "unsupported timezone; use UTC, +HH:MM, -HH:MM, local or an IANA Area/City name",
  )
}

///|
/// Canonical persisted identity: `UTC`, `+HH:MM`, `-HH:MM` or the IANA name.
/// `local` is never persisted; the host stores the resolved IANA name.
pub fn trigger_timezone_canonical(timezone : TriggerTimezone) -> String {
  match timezone {
    Utc => "UTC"
    Fixed(offset_seconds~) =>
      if offset_seconds >= 0 {
        "+" + trigger_offset_text(offset_seconds)
      } else {
        "-" + trigger_offset_text(-offset_seconds)
      }
    Iana(name~) => name
    Local => "local"
  }
}

///|
fn trigger_offset_text(seconds : Int) -> String {
  let hours = seconds / 3600
  let minutes = (seconds % 3600) / 60
  trigger_pad2(hours) + ":" + trigger_pad2(minutes)
}

///|
fn trigger_pad2(value : Int) -> String {
  if value < 10 {
    "0" + value.to_string()
  } else {
    value.to_string()
  }
}

///|
/// IANA names are a bounded `Area/City` path. This rejects traversal and
/// arbitrary file paths before any `read_file` call.
pub fn trigger_iana_name_valid(name : String) -> Bool {
  if name == "" || name.length() > 64 || name.has_prefix("/") ||
    name.has_suffix("/") {
    return false
  }
  let mut segments = 0
  let mut segment_length = 0
  for ch in name {
    let code = ch.to_int()
    let alpha_num = (code >= 97 && code <= 122) ||
      (code >= 65 && code <= 90) ||
      (code >= 48 && code <= 57)
    if ch == '/' {
      if segment_length == 0 {
        return false
      }
      segments = segments + 1
      segment_length = 0
      continue
    }
    if ch == '_' || ch == '-' || ch == '+' || alpha_num {
      segment_length = segment_length + 1
      continue
    }
    return false
  }
  segments >= 1 && segment_length > 0
}

///|
fn trigger_two_digits(text : String, start : Int) -> Int? {
  let first = match text.get_char(start) {
    Some(value) => value
    None => return None
  }
  let second = match text.get_char(start + 1) {
    Some(value) => value
    None => return None
  }
  if first < '0' || first > '9' || second < '0' || second > '9' {
    return None
  }
  Some((first.to_int() - 48) * 10 + (second.to_int() - 48))
}

///|
/// Strict `HH:MM`, 00:00..23:59. Minutes only: seconds, ranges and lists are
/// deliberately not part of the syntax (ADR-0014 §3.1).
pub fn trigger_schedule_at_valid(text : String) -> Bool {
  match trigger_schedule_at_parts(text) {
    Some(_) => true
    None => false
  }
}

///|
pub fn trigger_schedule_at_parts(text : String) -> (Int, Int)? {
  if text.length() != 5 || text.get_char(2) != Some(':') {
    return None
  }
  let hour = trigger_two_digits(text, 0)
  let minute = trigger_two_digits(text, 3)
  match (hour, minute) {
    (Some(h), Some(m)) =>
      if h <= 23 && m <= 59 {
        Some((h, m))
      } else {
        None
      }
    _ => None
  }
}

///|
/// Validate the schedule fields of a `TriggerSource`. Cross-type field
/// rejection (event fields on a schedule, etc.) is done by the host because
/// it is the one place that knows the trigger type.
pub fn schedule_parse(
  source : TriggerSource,
) -> Result[TriggerScheduleSpec, String] {
  let kind = source.schedule_kind
  if kind != TRIGGER_SCHEDULE_KIND_EVERY &&
    kind != TRIGGER_SCHEDULE_KIND_DAILY &&
    kind != TRIGGER_SCHEDULE_KIND_WEEKLY {
    return Err("source.schedule_kind must be every, daily or weekly")
  }
  if source.jitter_s < 0 || source.jitter_s > TRIGGER_SCHEDULE_JITTER_MAX_S {
    return Err("source.jitter_s must be within 0..300")
  }
  if source.missed != "skip" && source.missed != "coalesce_once" {
    return Err("source.missed must be skip or coalesce_once")
  }
  if kind == TRIGGER_SCHEDULE_KIND_EVERY {
    if source.interval_minutes < TRIGGER_SCHEDULE_INTERVAL_MIN ||
      source.interval_minutes > TRIGGER_SCHEDULE_INTERVAL_MAX {
      return Err("source.interval_minutes must be within 1..1440")
    }
    if source.at != "" || source.weekday != 0 {
      return Err("every accepts only interval_minutes, timezone and jitter_s")
    }
    return Ok(
      TriggerScheduleSpec::new(
        kind~,
        interval_minutes=source.interval_minutes,
        jitter_s=source.jitter_s,
        missed=source.missed,
      ),
    )
  }
  let parts = match trigger_schedule_at_parts(source.at) {
    Some(values) => values
    None => return Err("source.at must be HH:MM")
  }
  let (hour, minute) = parts
  if kind == TRIGGER_SCHEDULE_KIND_DAILY {
    if source.interval_minutes != 0 || source.weekday != 0 {
      return Err("daily accepts only at, timezone and jitter_s")
    }
    return Ok(
      TriggerScheduleSpec::new(
        kind~,
        at_hour=hour,
        at_minute=minute,
        jitter_s=source.jitter_s,
        missed=source.missed,
      ),
    )
  }
  if source.weekday < 1 || source.weekday > 7 {
    return Err("source.weekday must be 1..7 (ISO Monday..Sunday)")
  }
  if source.interval_minutes != 0 {
    return Err("weekly accepts only weekday, at, timezone and jitter_s")
  }
  Ok(
    TriggerScheduleSpec::new(
      kind~,
      at_hour=hour,
      at_minute=minute,
      weekday=source.weekday,
      jitter_s=source.jitter_s,
      missed=source.missed,
    ),
  )
}

///|
/// Build the UTC zone. Kept here so schedule tests do not need the host.
pub fn trigger_zone_utc() -> @time.Zone {
  @time.utc_zone
}

///|
pub fn trigger_zone_fixed(offset_seconds : Int) -> Result[@time.Zone, String] {
  if offset_seconds < -12 * 3600 || offset_seconds > 14 * 3600 {
    return Err("fixed offset must be within -12:00..+14:00")
  }
  let id = trigger_timezone_canonical(Fixed(offset_seconds=offset_seconds))
  let zone = @time.fixed_zone(id, offset_seconds) catch {
    error => return Err("invalid fixed timezone: " + error.to_string())
  }
  Ok(zone)
}

///|
/// Parse a TZif file. Reading the file is the host's job; this function keeps
/// the parse + error mapping pure so both `MONEXUS_TZDATA_DIR` and the system
/// directory use the same validation.
pub fn trigger_zone_from_tzif(
  name : String,
  data : BytesView,
) -> Result[@time.Zone, String] {
  if !trigger_iana_name_valid(name) {
    return Err("invalid IANA timezone name")
  }
  let zone = @time.Zone::from_tzif(name, data) catch {
    error =>
      return Err("cannot parse TZif for " + name + ": " + error.to_string())
  }
  Ok(zone)
}

///|
fn trigger_ms_to_seconds(ms : Int64) -> Int64 {
  if ms >= 0L || ms % 1000L == 0L {
    ms / 1000L
  } else {
    ms / 1000L - 1L
  }
}

///|
fn trigger_weekday_number(day : @time.Weekday) -> Int {
  match day {
    @time.Weekday::Monday => 1
    @time.Weekday::Tuesday => 2
    @time.Weekday::Wednesday => 3
    @time.Weekday::Thursday => 4
    @time.Weekday::Friday => 5
    @time.Weekday::Saturday => 6
    @time.Weekday::Sunday => 7
  }
}

///|
/// Resolve one local `HH:MM` reading to UTC milliseconds using the adr's DST
/// rules: a repeated local time uses the earlier instant (fold=0), and a
/// time skipped by a spring-forward jump uses the first valid instant after
/// the jump. `@time.Disambiguation::Compatible` shifts a gap by the whole gap
/// duration, which is not what ADR-0014 §3.2 asks for, so a gap is resolved
/// by finding the offset transition between the `Earlier` and `Compatible`
/// results.
pub fn trigger_local_slot_ms(
  zone : @time.Zone,
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
) -> Result[Int64, String] {
  let earlier = @time.date_time(
    year,
    month,
    day,
    hour=hour,
    minute=minute,
    zone=zone,
    disambiguation=@time.Disambiguation::Earlier,
  ) catch {
    error =>
      return Err("cannot resolve local schedule time: " + error.to_string())
  }
  let earlier_second = earlier.to_unix_second()
  if earlier.hour() == hour && earlier.minute() == minute {
    // Unambiguous, or the earlier occurrence of a fall-back overlap.
    return Ok(earlier_second * 1000L)
  }
  let compatible = @time.date_time(
    year,
    month,
    day,
    hour=hour,
    minute=minute,
    zone=zone,
    disambiguation=@time.Disambiguation::Compatible,
  ) catch {
    error =>
      return Err("cannot resolve local schedule time: " + error.to_string())
  }
  let compatible_second = compatible.to_unix_second()
  if compatible_second <= earlier_second {
    return Ok(compatible_second * 1000L)
  }
  let base_offset = match trigger_offset_seconds_at(zone, earlier_second) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  // Binary search the transition second: the first instant whose offset no
  // longer matches the pre-jump offset. DST transitions are at least one
  // second wide, so integer seconds are enough for an exact answer.
  let mut low = earlier_second + 1L
  let mut high = compatible_second
  while low < high {
    let middle = low + (high - low) / 2L
    let offset = match trigger_offset_seconds_at(zone, middle) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    if offset == base_offset {
      low = middle + 1L
    } else {
      high = middle
    }
  }
  Ok(low * 1000L)
}

///|
fn trigger_offset_seconds_at(
  zone : @time.Zone,
  second : Int64,
) -> Result[Int, String] {
  let value = @time.unix(second, zone=zone) catch {
    error => return Err("cannot resolve zone offset: " + error.to_string())
  }
  Ok(value.offset().seconds())
}

///|
/// Next slot strictly after `after_ms`. `every` advances on the frozen UTC
/// anchor; `daily`/`weekly` use the resolved local zone and the adr's DST
/// policy.
pub fn schedule_next_slot(
  spec : TriggerScheduleSpec,
  zone : @time.Zone,
  anchor_ms : Int64,
  after_ms : Int64,
) -> Result[Int64, String] {
  if spec.kind == TRIGGER_SCHEDULE_KIND_EVERY {
    let step = spec.interval_minutes.to_int64() * 60_000L
    if after_ms < anchor_ms {
      return Ok(anchor_ms)
    }
    let elapsed = after_ms - anchor_ms
    let slots = elapsed / step + 1L
    return Ok(anchor_ms + slots * step)
  }
  let after_sec = trigger_ms_to_seconds(after_ms)
  let after_local = @time.unix(after_sec, zone=zone) catch {
    error => return Err("cannot resolve local date: " + error.to_string())
  }
  let start = after_local.to_plain_date()
  // A weekly candidate is at most 14 days away; DST cannot move a local
  // clock reading by more than a day, so a 400-day guard is generous.
  for offset in 0..<400 {
    let date = start.add_days(offset.to_int64()) catch {
      error => return Err("cannot advance local date: " + error.to_string())
    }
    if spec.kind == TRIGGER_SCHEDULE_KIND_WEEKLY &&
      trigger_weekday_number(date.weekday()) != spec.weekday {
      continue
    }
    let candidate_ms = match trigger_local_slot_ms(
      zone,
      date.year(),
      date.month(),
      date.day(),
      spec.at_hour,
      spec.at_minute,
    ) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    if candidate_ms > after_ms {
      return Ok(candidate_ms)
    }
  }
  Err("cannot find the next schedule slot")
}

///|
/// Deterministic delay in milliseconds, derived only from the trigger id and
/// the slot. Recomputing after a restart yields the same delay, and the slot
/// key itself never includes it (ADR-0014 §3.3).
pub fn schedule_jitter_ms(
  trigger_id : String,
  scheduled_for_ms : Int64,
  jitter_s : Int,
) -> Int64 {
  let maximum = jitter_s.max(0).min(TRIGGER_SCHEDULE_JITTER_MAX_S)
  if maximum == 0 {
    return 0L
  }
  let mut hash : UInt64 = 14_695_981_039_346_656_037UL
  let text = trigger_id + ":" + scheduled_for_ms.to_string()
  for ch in text {
    hash = (hash ^ ch.to_int().to_uint64()) * 1_099_511_628_211UL
  }
  let span = (maximum.to_int64() * 1000L + 1L).reinterpret_as_uint64()
  (hash % span).reinterpret_as_int64()
}

///|
/// A wall clock that moved back by more than five minutes relative to the
/// persisted tick. Small NTP corrections are accepted; a large rollback must
/// not replay slots (ADR-0014 §3.4).
pub fn trigger_clock_skewed(now_ms : Int64, last_tick_ms : Int64) -> Bool {
  last_tick_ms - now_ms > TRIGGER_CLOCK_SKEW_MS
}

///|
/// `now >= scheduled_for + jitter`. Jitter delays execution but not identity.
pub fn schedule_is_due(
  spec : TriggerScheduleSpec,
  trigger_id : String,
  scheduled_for_ms : Int64,
  now_ms : Int64,
) -> Bool {
  now_ms >= scheduled_for_ms +
    schedule_jitter_ms(trigger_id, scheduled_for_ms, spec.jitter_s)
}

///|
/// Missed-window analysis for one due slot. `latest_slot_ms` is the most
/// recent slot at or before `now`; `next_slot_ms` is the first future slot.
pub(all) struct ScheduleMissed {
  due_count : Int
  latest_slot_ms : Int64
  next_slot_ms : Int64
  too_old : Bool
}

///|
/// Compute how many slots have been missed since the persisted `slot_ms`.
/// The result is bounded: `every` is analytic, and daily/weekly stop after a
/// generous day guard. A slot older than the 90-day ledger is always marked
/// `too_old`, which forces the skip path for `coalesce_once`.
pub fn schedule_missed(
  spec : TriggerScheduleSpec,
  zone : @time.Zone,
  anchor_ms : Int64,
  slot_ms : Int64,
  now_ms : Int64,
) -> Result[ScheduleMissed, String] {
  if slot_ms > now_ms {
    return Ok(
      {
        due_count: 0,
        latest_slot_ms: slot_ms,
        next_slot_ms: slot_ms,
        too_old: false,
      },
    )
  }
  let retention_ms = TRIGGER_SLOT_RETENTION_DAYS.to_int64() *
    24L * 3600L * 1000L
  let old_floor = now_ms - retention_ms
  if spec.kind == TRIGGER_SCHEDULE_KIND_EVERY {
    let step = spec.interval_minutes.to_int64() * 60_000L
    let elapsed = now_ms - slot_ms
    let after_current = elapsed / step
    let count = after_current + 1L
    let latest = slot_ms + after_current * step
    let next = slot_ms + count * step
    let due_count = if count > 1_000_000L { 1_000_000 } else { count.to_int() }
    return Ok(
      {
        due_count,
        latest_slot_ms: latest,
        next_slot_ms: next,
        too_old: latest < old_floor,
      },
    )
  }
  let mut latest = slot_ms
  let mut count = 1
  for _ in 0..<20_000 {
    let next = match schedule_next_slot(spec, zone, anchor_ms, latest) {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    if next > now_ms {
      return Ok(
        {
          due_count: count,
          latest_slot_ms: latest,
          next_slot_ms: next,
          too_old: latest < old_floor,
        },
      )
    }
    latest = next
    count = count + 1
  }
  // Extremely long backlog: the exact count is not operationally useful, and
  // the next future slot is still computed directly from `now`.
  let next = match schedule_next_slot(spec, zone, anchor_ms, now_ms) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok(
    {
      due_count: count,
      latest_slot_ms: latest,
      next_slot_ms: next,
      too_old: true,
    },
  )
}
