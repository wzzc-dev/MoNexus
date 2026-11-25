///|
/// A3.0 contract tests: pure matching, templating, hashing, dedupe keys,
/// rate buckets, expiry and redaction. No dispatcher or HTTP is involved.

///|
fn sample_source() -> TriggerSource {
  TriggerSource::new(
    event_type="task.created",
    payload_fields=["title"],
  )
}

///|
fn sample_target() -> TriggerTarget {
  TriggerTarget::new(
    title_template="Hello {{title}}",
    goal_template="goal for {{title}}",
  )
}

///|
fn sample_record() -> TriggerRecord {
  TriggerRecord::new(
    id="trg_01HZZZZZZZZZZZZZZZZZZZZZZZ",
    org_id=ORG_LOCAL,
    name="demo",
    kind=TRIGGER_TYPE_EVENT,
    target=sample_target(),
    source=sample_source(),
    config_hash="sha256:test",
    created_by="owner",
    created_at="2026-01-01T00:00:00.000Z",
    active_from_seq=10L,
  )
}

///|
fn sample_origin(trigger_id : String, depth : Int) -> TriggerOrigin {
  TriggerOrigin::new(
    trigger_id~,
    fire_key="event:evt_1",
    root_trigger_id=trigger_id,
    depth~,
    source=TRIGGER_SOURCE_EVENT,
  )
}

///|
test "event match is exact or a trailing .* prefix only" {
  let source = TriggerSource::new(event_type="run.*")
  assert_eq(
    match_event_trigger("trg_1", source, "run.failed", "run/x", "", None),
    TriggerMatch,
  )
  assert_eq(
    match_event_trigger("trg_1", source, "run", "run/x", "", None),
    TriggerNoMatch,
  )
  assert_eq(
    match_event_trigger("trg_1", source, "task.created", "task/x", "", None),
    TriggerNoMatch,
  )
  let exact = TriggerSource::new(event_type="task.created")
  assert_eq(
    match_event_trigger("trg_1", exact, "task.created", "task/1", "", None),
    TriggerMatch,
  )
  // A mid-string wildcard is not a pattern.
  let bad = TriggerSource::new(event_type="task.*.created")
  assert_eq(
    match_event_trigger("trg_1", bad, "task.x.created", "task/1", "", None),
    TriggerNoMatch,
  )
}

///|
test "high-volume and meta events never match" {
  for event_type in [
    "host.heartbeat", "audit.recorded", "run.progress", "run.heartbeat",
    "agent.session.output", "agent.session.updated", "trigger.created",
    "trigger.fired", "trigger.rejected",
  ] {
    let source = TriggerSource::new(event_type="*")
    // `*` alone is not a valid prefix pattern, but the blacklist runs first.
    assert_eq(
      match_event_trigger("trg_1", source, event_type, "", "", None),
      TriggerNoMatch,
    )
  }
}

///|
test "subject prefix and correlation filter narrow a match" {
  let source = TriggerSource::new(
    event_type="task.created",
    subject_prefix="task/tsk_",
    correlation_id="corr-1",
  )
  assert_eq(
    match_event_trigger(
      "trg_1", source, "task.created", "task/tsk_1", "corr-1", None,
    ),
    TriggerMatch,
  )
  assert_eq(
    match_event_trigger(
      "trg_1", source, "task.created", "task/other", "corr-1", None,
    ),
    TriggerNoMatch,
  )
  assert_eq(
    match_event_trigger(
      "trg_1", source, "task.created", "task/tsk_1", "corr-2", None,
    ),
    TriggerNoMatch,
  )
}

///|
test "ignore_self skips its own Task and cascade depth caps at eight" {
  let source = TriggerSource::new(event_type="task.created")
  assert_eq(
    match_event_trigger(
      "trg_1", source, "task.created", "task/1", "", Some(sample_origin("trg_1", 1)),
    ),
    TriggerIgnoreSelf,
  )
  assert_eq(
    match_event_trigger(
      "trg_1", source, "task.created", "task/1", "", Some(sample_origin("trg_2", 1)),
    ),
    TriggerMatch,
  )
  assert_eq(
    match_event_trigger(
      "trg_1", source, "task.created", "task/1", "", Some(sample_origin("trg_2", 8)),
    ),
    TriggerCascadeDepth,
  )
  let no_ignore = TriggerSource::new(
    event_type="task.created",
    ignore_self=false,
  )
  assert_eq(
    match_event_trigger(
      "trg_1", no_ignore, "task.created", "task/1", "", Some(sample_origin("trg_1", 1)),
    ),
    TriggerMatch,
  )
}

///|
test "cascade depth and root travel with the origin" {
  assert_eq(trigger_next_depth(None), 1)
  assert_eq(trigger_next_depth(Some(sample_origin("trg_1", 3))), 4)
  assert_eq(trigger_origin_root(None, "trg_self"), "trg_self")
  assert_eq(trigger_origin_root(Some(sample_origin("trg_2", 2)), "trg_self"), "trg_2")
}

///|
test "event type patterns are bounded and reject wildcards" {
  assert_eq(trigger_event_type_valid("run.failed"), true)
  assert_eq(trigger_event_type_valid("run.*"), true)
  assert_eq(trigger_event_type_valid(""), false)
  assert_eq(trigger_event_type_valid("*.failed"), false)
  assert_eq(trigger_event_type_valid("run.*.failed"), false)
  assert_eq(trigger_event_type_valid("run.?"), false)
  assert_eq(trigger_event_type_valid("run. failed"), false)
}

///|
test "template rendering is bounded text substitution, never a shell" {
  let vars : Map[String, String] = Map([
    ("title", "fix $(rm -rf /) ; echo hi"),
    ("empty", ""),
  ])
  let rendered = render_template(
    "T: {{title}} U: {{unknown}} E: {{empty}}",
    vars,
    200,
  )
  assert_eq(rendered, "T: fix $(rm -rf /) ; echo hi U:  E: ")
  // No `$()` evaluation: the literal text survives unchanged.
  assert_eq(rendered.contains("rm -rf"), true)
  // Unknown placeholders become empty, never an error.
  assert_eq(render_template("{{missing}}", vars, 10), "")
  // Result is capped.
  let long = render_template("abcdef", Map([]), 3)
  assert_eq(long, "abc")
  // Unterminated braces are copied literally.
  assert_eq(render_template("a {{title", vars, 100), "a {{title")
}

///|
test "config hash is canonical, stable and covers only typed fields" {
  let target = TriggerTarget::new(title_template="Hello")
  let source = TriggerSource::new(event_type="task.created")
  let hash = trigger_config_hash(
    "demo",
    TRIGGER_TYPE_EVENT,
    true,
    "",
    target,
    source,
  )
  assert_eq(
    hash,
    "sha256:225957b26bbcace309ea9fa6e72cf9029edcc40b4d9bea8207d34ae8c39cba16",
  )
  // Field order in the JSON object does not affect the digest.
  let same = trigger_config_hash(
    "demo",
    TRIGGER_TYPE_EVENT,
    true,
    "",
    TriggerTarget::new(title_template="Hello"),
    TriggerSource::new(event_type="task.created"),
  )
  assert_eq(hash, same)
  // Changing a real config field changes the digest.
  let changed = trigger_config_hash(
    "demo",
    TRIGGER_TYPE_EVENT,
    true,
    "",
    TriggerTarget::new(title_template="Hello!"),
    source,
  )
  assert_eq(hash == changed, false)
  // A secret-looking key never reaches the canonical JSON.
  let tainted = @json.parse(
    "{\"title_template\":\"x\",\"env\":\"SECRET\"}",
  ) catch {
    _ => @json.Json::null()
  }
  let canonical = trigger_canonical_json(tainted)
  assert_eq(canonical.contains("SECRET"), false)
  assert_eq(canonical.contains("env"), false)
}

///|
test "dedupe keys are deterministic and namespaced" {
  assert_eq(trigger_event_fire_key("evt_1"), "event:evt_1")
  assert_eq(trigger_manual_fire_key("req-1"), "manual:req-1")
  assert_eq(trigger_slot_fire_key(1_700_000_000_000L), "slot:1700000000000")
  let task_key = trigger_task_event_idempotency("trg_1", "event:evt_1")
  assert_eq(task_key, "trigger/trg_1/event:evt_1/task")
  let fired_key = "trigger/trg_1/event:evt_1/fired"
  assert_eq(task_key == fired_key, false)
  assert_eq(task_key.contains("trg_1"), true)
  assert_eq(task_key.contains("evt_1"), true)
  assert_eq(trigger_run_idempotency("trg_1", "event:evt_1"), "trigger:trg_1:event:evt_1")
}

///|
test "rate bucket enforces burst then refills by time" {
  let now = 1_700_000_000_000L
  let (bucket, first) = trigger_rate_take(
    trigger_rate_bucket_new(now, 1),
    now,
    30,
    1,
  )
  assert_eq(first, true)
  let (bucket2, second) = trigger_rate_take(bucket, now, 30, 1)
  assert_eq(second, false)
  // 30/min = 1 token per 2 seconds.
  let (_, refilled) = trigger_rate_take(bucket2, now + 2_000L, 30, 1)
  assert_eq(refilled, true)
  // A clock rollback cannot mint tokens.
  let (rolled, taken) = trigger_rate_take(
    trigger_rate_bucket_new(now, 5),
    now - 60_000L,
    30,
    5,
  )
  assert_eq(taken, true)
  assert_eq(rolled.tokens_milli, 4_000L)
  assert_eq(rolled.last_ms, now - 60_000L)
}

///|
test "RFC3339 expiry parses UTC and rejects offsets" {
  assert_eq(
    trigger_parse_rfc3339_ms("2023-11-14T22:13:20.123Z"),
    Some(1_700_000_000_123L),
  )
  assert_eq(trigger_parse_rfc3339_ms(""), None)
  assert_eq(trigger_parse_rfc3339_ms("2023-11-14T22:13:20+01:00"), None)
  assert_eq(trigger_parse_rfc3339_ms("not-a-time"), None)
  assert_eq(trigger_is_expired_at("", 100L), false)
  assert_eq(
    trigger_is_expired_at("2023-11-14T22:13:20.123Z", 1_700_000_000_123L),
    true,
  )
  assert_eq(
    trigger_is_expired_at("2023-11-14T22:13:20.123Z", 1_700_000_000_000L),
    false,
  )
}

///|
test "derived state reflects enabled and expiry" {
  let record = sample_record()
  assert_eq(trigger_state_of(record, 0L), TRIGGER_STATE_ACTIVE)
  assert_eq(trigger_is_active_at(record, 0L), true)
  let disabled = { ..record, enabled: false }
  assert_eq(trigger_state_of(disabled, 0L), TRIGGER_STATE_DISABLED)
  let expired = { ..record, expires_at: "2023-11-14T22:13:20.123Z" }
  assert_eq(trigger_state_of(expired, 1_700_000_000_123L), TRIGGER_STATE_EXPIRED)
  assert_eq(trigger_is_active_at(expired, 1_700_000_000_123L), false)
}

///|
test "forbidden trigger config fields are rejected recursively" {
  assert_eq(trigger_forbidden_config_field("command"), true)
  assert_eq(trigger_forbidden_config_field("env"), true)
  assert_eq(trigger_forbidden_config_field("approval"), true)
  assert_eq(trigger_forbidden_config_field("api_key"), true)
  assert_eq(trigger_forbidden_config_field("title_template"), false)
  let json = @json.parse(
    "{\"target\":{\"title_template\":\"x\"},\"source\":{\"env\":[]}}",
  ) catch {
    _ => @json.Json::null()
  }
  assert_eq(trigger_config_has_forbidden_field(json), true)
  let clean = TriggerTarget::new(title_template="ok").to_json()
  assert_eq(trigger_config_has_forbidden_field(clean), false)
}

///|
test "rejected payload redacts secrets and carries source links" {
  let payload = trigger_rejected_payload(
    "trg_1",
    TRIGGER_SOURCE_EVENT,
    TRIGGER_REJECT_RATE_LIMITED,
    "token sk-abc1234567890 rejected",
    event_id="evt_1",
  )
  let text = payload.stringify()
  assert_eq(text.contains("sk-abc1234567890"), false)
  assert_eq(text.contains("evt_1"), true)
  assert_eq(text.contains("rate_limited"), true)
  // Dedupe drops have no per-drop event; the builder has no dedupe reason.
  assert_eq(text.contains("dedupe"), false)
}
