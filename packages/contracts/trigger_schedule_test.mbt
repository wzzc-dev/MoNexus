///|
/// A3.1 schedule contract tests: strict syntax, timezone classification,
/// fixed-offset and IANA/DST slot resolution, missed-window policy inputs,
/// jitter determinism and clock-skew detection. All pure, no sleeping.

///|
fn timezone_ok(text : String) -> Bool {
  match trigger_timezone_parse(text) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn schedule_ok(source : TriggerSource) -> Bool {
  match schedule_parse(source) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn schedule_bad(source : TriggerSource) -> Bool {
  match schedule_parse(source) {
    Ok(_) => false
    Err(_) => true
  }
}

///|
fn tzif_u32(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 24) & 255).to_byte())
  out.push(((value >> 16) & 255).to_byte())
  out.push(((value >> 8) & 255).to_byte())
  out.push((value & 255).to_byte())
}

///|
fn tzif_i32(out : Array[Byte], value : Int) -> Unit {
  out.push(((value >> 24) & 255).to_byte())
  out.push(((value >> 16) & 255).to_byte())
  out.push(((value >> 8) & 255).to_byte())
  out.push((value & 255).to_byte())
}

///|
/// Minimal TZif v1 file with US Eastern rules: EST (-05:00) until
/// 2026-03-08T07:00Z, EDT (-04:00) until 2026-11-01T06:00Z, then EST again.
/// Used to exercise the DST gap and overlap rules without system tzdata.
fn schedule_test_tzif() -> Bytes {
  let out : Array[Byte] = []
  // Header: magic, version 1, 15 reserved bytes, six u32 counts.
  for ch in "TZif" {
    out.push(ch.to_int().to_byte())
  }
  out.push(b'\x00')
  for _ in 0..<15 {
    out.push(b'\x00')
  }
  tzif_u32(out, 0) // UT/local indicators
  tzif_u32(out, 0) // standard/wall indicators
  tzif_u32(out, 0) // leap records
  tzif_u32(out, 2) // transitions
  tzif_u32(out, 2) // local time types
  tzif_u32(out, 8) // designation bytes
  // Transitions: 2026-03-08T07:00Z, 2026-11-01T06:00Z.
  tzif_i32(out, 1_772_953_200)
  tzif_i32(out, 1_793_512_800)
  out.push(b'\x01')
  out.push(b'\x00')
  // Type 0: EST, type 1: EDT.
  tzif_i32(out, -18_000)
  out.push(b'\x00')
  out.push(b'\x00')
  tzif_i32(out, -14_400)
  out.push(b'\x01')
  out.push(b'\x04')
  for ch in "EST" {
    out.push(ch.to_int().to_byte())
  }
  out.push(b'\x00')
  for ch in "EDT" {
    out.push(ch.to_int().to_byte())
  }
  out.push(b'\x00')
  Bytes::from_array(out)
}

///|
fn schedule_test_zone() -> @time.Zone raise {
  match trigger_zone_from_tzif("Test/US_Eastern", schedule_test_tzif().exact_view()) {
    Ok(value) => value
    Err(message) => fail("synthetic TZif rejected: " + message)
  }
}

///|
test "timezone strings classify strictly and never fall back to UTC" {
  assert_eq(trigger_timezone_parse("").unwrap(), TriggerTimezone::Utc)
  assert_eq(trigger_timezone_parse(" UTC ").unwrap(), TriggerTimezone::Utc)
  assert_eq(trigger_timezone_parse("local").unwrap(), TriggerTimezone::Local)
  assert_eq(
    trigger_timezone_parse("+05:30").unwrap(),
    TriggerTimezone::Fixed(offset_seconds=19_800),
  )
  assert_eq(
    trigger_timezone_parse("-12:00").unwrap(),
    TriggerTimezone::Fixed(offset_seconds=-43_200),
  )
  assert_eq(
    trigger_timezone_parse("+14:00").unwrap(),
    TriggerTimezone::Fixed(offset_seconds=50_400),
  )
  assert_eq(
    trigger_timezone_parse("America/New_York").unwrap(),
    TriggerTimezone::Iana(name="America/New_York"),
  )
  assert_true(!timezone_ok("+14:01"))
  assert_true(!timezone_ok("-12:30"))
  assert_true(!timezone_ok("+5:30"))
  assert_true(!timezone_ok("Europe/Nowhere/../etc"))
  assert_true(!timezone_ok("../etc/passwd"))
  assert_true(!timezone_ok("GMT+2"))
  assert_eq(
    trigger_timezone_canonical(TriggerTimezone::Fixed(offset_seconds=19_800)),
    "+05:30",
  )
  assert_eq(
    trigger_timezone_canonical(TriggerTimezone::Fixed(offset_seconds=-43_200)),
    "-12:00",
  )
}

///|
test "schedule syntax accepts only the adr fields" {
  let every = TriggerSource::new(
    schedule_kind="every",
    interval_minutes=15,
    timezone="+02:00",
    jitter_s=30,
  )
  assert_true(schedule_ok(every))
  let daily = TriggerSource::new(
    schedule_kind="daily",
    at="09:30",
    timezone="Europe/Berlin",
  )
  assert_true(schedule_ok(daily))
  let weekly = TriggerSource::new(
    schedule_kind="weekly",
    weekday=1,
    at="00:00",
  )
  match schedule_parse(weekly) {
    Ok(spec) => assert_eq(spec.weekday, 1)
    Err(message) => fail("weekly rejected: " + message)
  }
  // Cron and extension fields are not part of the grammar.
  assert_true(
    schedule_bad(
      TriggerSource::new(schedule_kind="every", interval_minutes=0),
    ),
  )
  assert_true(
    schedule_bad(
      TriggerSource::new(schedule_kind="every", interval_minutes=1_441),
    ),
  )
  assert_true(
    schedule_bad(
      TriggerSource::new(
        schedule_kind="every",
        interval_minutes=5,
        at="09:00",
      ),
    ),
  )
  assert_true(
    schedule_bad(TriggerSource::new(schedule_kind="daily", at="9:00")),
  )
  assert_true(
    schedule_bad(TriggerSource::new(schedule_kind="daily", at="24:00")),
  )
  assert_true(
    schedule_bad(
      TriggerSource::new(schedule_kind="weekly", weekday=0, at="09:00"),
    ),
  )
  assert_true(
    schedule_bad(
      TriggerSource::new(schedule_kind="weekly", weekday=8, at="09:00"),
    ),
  )
  assert_true(
    schedule_bad(
      TriggerSource::new(
        schedule_kind="daily",
        at="09:00",
        jitter_s=301,
      ),
    ),
  )
  assert_true(
    schedule_bad(
      TriggerSource::new(schedule_kind="daily", at="09:00", missed="all"),
    ),
  )
  assert_true(
    schedule_bad(
      TriggerSource::new(schedule_kind="cron", at="* * * * *"),
    ),
  )
}

///|
test "every advances on the frozen UTC anchor" {
  let spec = match schedule_parse(
    TriggerSource::new(schedule_kind="every", interval_minutes=1),
  ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let anchor = 1_767_225_600_000L
  // Before the anchor, the anchor itself is the slot.
  assert_eq(
    schedule_next_slot(spec, trigger_zone_utc(), anchor, anchor - 1L),
    Ok(anchor),
  )
  // 90s after the anchor: the next 1-minute slot is anchor + 2 minutes.
  assert_eq(
    schedule_next_slot(spec, trigger_zone_utc(), anchor, anchor + 90_000L),
    Ok(anchor + 120_000L),
  )
}

///|
test "daily and weekly use fixed offsets and IANA local time" {
  let daily = match schedule_parse(
    TriggerSource::new(schedule_kind="daily", at="09:00"),
  ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let zone = match trigger_zone_fixed(19_800) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  // 2026-03-08T00:00Z is 05:30 local; 09:00 local is 03:30Z.
  assert_eq(
    schedule_next_slot(daily, zone, 0L, 1_772_928_000_000L),
    Ok(1_772_940_600_000L),
  )
  let weekly = match schedule_parse(
    TriggerSource::new(schedule_kind="weekly", weekday=1, at="09:00"),
  ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  // 2026-03-08 is a Sunday; the next Monday 09:00Z is 2026-03-09T09:00Z.
  assert_eq(
    schedule_next_slot(weekly, trigger_zone_utc(), 0L, 1_772_964_000_000L),
    Ok(1_773_046_800_000L),
  )
}

///|
test "dst gap resolves to the first valid instant after the jump" {
  let zone = schedule_test_zone()
  // 02:30 on 2026-03-08 does not exist in US Eastern; the first valid
  // instant after the jump is 03:00 EDT = 07:00Z.
  assert_eq(
    trigger_local_slot_ms(zone, 2026, 3, 8, 2, 30),
    Ok(1_772_953_200_000L),
  )
  let daily = match schedule_parse(
    TriggerSource::new(schedule_kind="daily", at="02:30"),
  ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  // Starting from within 2026-03-08, the gap slot is the next daily slot.
  assert_eq(
    schedule_next_slot(daily, zone, 0L, 1_772_928_000_000L),
    Ok(1_772_953_200_000L),
  )
}

///|
test "dst overlap uses the earlier occurrence" {
  let zone = schedule_test_zone()
  // 01:30 on 2026-11-01 happens twice; fold=0 is 05:30Z, not 06:30Z.
  assert_eq(
    trigger_local_slot_ms(zone, 2026, 11, 1, 1, 30),
    Ok(1_793_511_000_000L),
  )
  // A normal local time is unaffected: 12:00 EDT is 16:00Z.
  assert_eq(
    trigger_local_slot_ms(zone, 2026, 6, 1, 12, 0),
    Ok(1_780_329_600_000L),
  )
}

///|
test "every never observes DST because it stays UTC" {
  let spec = match schedule_parse(
    TriggerSource::new(schedule_kind="every", interval_minutes=60),
  ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let zone = schedule_test_zone()
  // 06:00Z, 07:00Z, 08:00Z are consecutive hourly slots across the jump.
  assert_eq(
    schedule_next_slot(spec, zone, 1_772_949_600_000L, 1_772_951_400_000L),
    Ok(1_772_953_200_000L),
  )
}

///|
test "missed windows count due slots and expose the next future slot" {
  let every = match schedule_parse(
    TriggerSource::new(schedule_kind="every", interval_minutes=60),
  ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let anchor = 1_767_225_600_000L
  let now = anchor + 3L * 3_600_000L
  match schedule_missed(every, trigger_zone_utc(), anchor, anchor, now) {
    Ok(missed) => {
      assert_eq(missed.due_count, 4)
      assert_eq(missed.latest_slot_ms, now)
      assert_eq(missed.next_slot_ms, now + 3_600_000L)
      assert_true(!missed.too_old)
    }
    Err(message) => fail(message)
  }
  // A 100-day backlog: the latest slot to coalesce is `now` itself, so the
  // 90-day retention guard does not fire for an in-grammar interval.
  let hundred_days = 100L * 86_400_000L
  match schedule_missed(
    every,
    trigger_zone_utc(),
    anchor,
    anchor,
    anchor + hundred_days,
  ) {
    Ok(missed) => {
      assert_eq(missed.due_count, 2_401)
      assert_eq(missed.latest_slot_ms, anchor + hundred_days)
      assert_eq(missed.next_slot_ms, anchor + hundred_days + 3_600_000L)
      assert_true(!missed.too_old)
    }
    Err(message) => fail(message)
  }
  // Defensive guard: a coalesced latest slot older than the 90-day ledger is
  // always skipped. Valid schedule grammar intervals (<= 1440 minutes) keep
  // the latest slot within one interval of `now`, so this only arises for a
  // corrupted/oversized interval record.
  let coarse = TriggerScheduleSpec::new(
    kind="every",
    interval_minutes=200_000,
  )
  match schedule_missed(
    coarse,
    trigger_zone_utc(),
    anchor,
    anchor,
    anchor + hundred_days,
  ) {
    Ok(missed) => {
      assert_true(missed.too_old)
      assert_eq(missed.latest_slot_ms, anchor)
    }
    Err(message) => fail(message)
  }
  let daily = match schedule_parse(
    TriggerSource::new(schedule_kind="daily", at="09:00"),
  ) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  // Persisted slot 2026-03-01T09:00Z, now 2026-03-04T10:00Z.
  match schedule_missed(
    daily,
    trigger_zone_utc(),
    0L,
    1_772_355_600_000L,
    1_772_618_400_000L,
  ) {
    Ok(missed) => {
      assert_eq(missed.due_count, 4)
      assert_eq(missed.latest_slot_ms, 1_772_614_800_000L)
      assert_eq(missed.next_slot_ms, 1_772_701_200_000L)
    }
    Err(message) => fail(message)
  }
}

///|
test "jitter is deterministic, bounded and independent of slot identity" {
  let first = schedule_jitter_ms("trg_01HZZZZZZZZZZZZZZZZZZZZZZZ", 1_772_928_000_000L, 300)
  let again = schedule_jitter_ms("trg_01HZZZZZZZZZZZZZZZZZZZZZZZ", 1_772_928_000_000L, 300)
  assert_eq(first, again)
  assert_true(first >= 0L && first <= 300_000L)
  let other_slot = schedule_jitter_ms("trg_01HZZZZZZZZZZZZZZZZZZZZZZZ", 1_772_928_060_000L, 300)
  assert_true(other_slot >= 0L && other_slot <= 300_000L)
  assert_eq(schedule_jitter_ms("trg_x", 1_772_928_000_000L, 0), 0L)
  let spec = TriggerScheduleSpec::new(kind="every", interval_minutes=1, jitter_s=300)
  let slot = 1_772_928_000_000L
  let jitter = schedule_jitter_ms("trg_x", slot, 300)
  assert_true(!schedule_is_due(spec, "trg_x", slot, slot + jitter - 1L))
  assert_true(schedule_is_due(spec, "trg_x", slot, slot + jitter))
}

///|
test "clock rollback beyond five minutes is detected" {
  let now = 1_767_225_600_000L
  assert_true(!trigger_clock_skewed(now, now))
  assert_true(!trigger_clock_skewed(now, now + 300_000L))
  assert_true(trigger_clock_skewed(now, now + 300_001L))
}

