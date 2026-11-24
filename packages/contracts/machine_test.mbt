///|
/// Machine contract tests: validation, JSON round-trip, readable errors and
/// event payload helpers. They are pure and need neither SQLite nor ssh.

///|
fn sample_machine() -> MachineRecord {
  {
    id: "mch_test",
    kind: MACHINE_KIND_SSH,
    name: "box",
    host: "example.com",
    port: 2222,
    user: "tester",
    identity: "/tmp/key",
    use_ssh_config: false,
    host_key_policy: MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    known_hosts_file: "/tmp/kh",
    status: MACHINE_STATUS_ONLINE,
    profile: Some(
      MachineProfile::new(
        arch="x86_64",
        os="Linux",
        hostname="box",
        shell="/bin/bash",
        toolchains=Map([("git", "/usr/bin/git")]),
        has_docker=true,
        max_parallel=8,
      ),
    ),
    ssh_effective: Map([("hostname", "example.com"), ("port", "2222")]),
    ssh_effective_error: "",
    last_seen: "2026-01-01T00:00:00Z",
    last_error: "",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
}

///|
test "machine add params round-trip through validation and trimming" {
  let params = machine_add_params(
    "req_1",
    name="",
    host="  example.com  ",
    port=2222,
    user="tester",
    identity="/tmp/key",
    use_ssh_config=false,
    host_key_policy=MACHINE_HOST_KEY_POLICY_STRICT,
    known_hosts_file="/tmp/kh",
  )
  let spec = match parse_machine_add(params) {
    Ok(value) => value
    Err(message) => fail("unexpected validation error: " + message)
  }
  assert_eq(spec.host, "example.com")
  // An empty name defaults to the host, matching the CLI and desktop.
  assert_eq(spec.name, "example.com")
  assert_eq(spec.port, 2222)
  assert_eq(spec.user, "tester")
  assert_eq(spec.use_ssh_config, false)
  assert_eq(spec.host_key_policy, MACHINE_HOST_KEY_POLICY_STRICT)
}

///|
test "machine add rejects option-like hosts and bad fields" {
  let bad_host = machine_add_params(
    "req_2",
    name="x",
    host="-oProxyCommand=evil",
    use_ssh_config=false,
  )
  match parse_machine_add(bad_host) {
    Ok(_) => fail("option-like host must be rejected")
    Err(message) => assert_true(message.contains("invalid host"))
  }
  let bad_port = machine_add_params("req_3", name="x", host="h", port=0)
  match parse_machine_add(bad_port) {
    Ok(_) => fail("port 0 must be rejected")
    Err(message) => assert_true(message.contains("invalid port"))
  }
  let bad_user = machine_add_params(
    "req_4",
    name="x",
    host="h",
    user="bad user",
  )
  match parse_machine_add(bad_user) {
    Ok(_) => fail("user with a space must be rejected")
    Err(message) => assert_true(message.contains("invalid user"))
  }
  let bad_policy = machine_add_params(
    "req_5",
    name="x",
    host="h",
    host_key_policy="bogus",
  )
  match parse_machine_add(bad_policy) {
    Ok(_) => fail("unknown host key policy must be rejected")
    Err(message) => assert_true(message.contains("invalid host_key_policy"))
  }
}

///|
test "machine record JSON round-trip keeps explicit target and profile" {
  let record = sample_machine()
  let parsed = match MachineRecord::from_json(record.to_json()) {
    Some(value) => value
    None => fail("machine record did not round-trip")
  }
  assert_eq(parsed.id, "mch_test")
  assert_eq(parsed.target_label(), "tester@example.com")
  assert_eq(parsed.port, 2222)
  assert_eq(parsed.identity, "/tmp/key")
  assert_eq(parsed.use_ssh_config, false)
  assert_eq(parsed.known_hosts_file, "/tmp/kh")
  assert_eq(parsed.ssh_effective.get("port"), Some("2222"))
  match parsed.profile {
    Some(profile) => {
      assert_eq(profile.os, "Linux")
      assert_eq(profile.arch, "x86_64")
      assert_eq(profile.max_parallel, 8)
      assert_true(profile.has_docker)
      assert_eq(profile.toolchains.get("git"), Some("/usr/bin/git"))
    }
    None => fail("profile was lost in the round-trip")
  }
}

///|
test "profile completeness drives online versus degraded" {
  let incomplete = MachineProfile::new(hostname="box")
  assert_false(incomplete.is_complete())
  assert_eq(incomplete.missing_fields(), "os, arch")
  let complete = MachineProfile::new(
    os="Linux",
    arch="x86_64",
    hostname="box",
  )
  assert_true(complete.is_complete())
  assert_eq(complete.missing_fields(), "")
}

///|
test "machine errors carry a readable label and first stderr line" {
  let error = machine_error(
    MACHINE_ERR_UNAUTHORIZED,
    "SSH authentication failed",
    detail="user@host: Permission denied (publickey).\nmore detail",
  )
  assert_eq(error.message, "Unauthorized: SSH authentication failed")
  assert_eq(
    machine_error_text(error),
    "Unauthorized: SSH authentication failed (user@host: Permission denied (publickey).)",
  )
  // No detail → just the label and reason.
  let concise = machine_error(MACHINE_ERR_TIMEOUT, "SSH connection timed out")
  assert_eq(machine_error_text(concise), "Timeout: SSH connection timed out")
}

///|
test "machine event helpers distinguish snapshots from tombstone ids" {
  let record = sample_machine()
  let probed = EventEnvelope::new(
    id="evt_1",
    org_id=ORG_LOCAL,
    event_type=EVENT_MACHINE_PROBED,
    ts="2026-01-01T00:00:01Z",
    subject="machine/mch_test",
    seq=1L,
    payload=machine_event_payload(record),
  )
  match machine_event_record(probed) {
    Some(found) => assert_eq(found.id, "mch_test")
    None => fail("machine.probed payload lost the record")
  }
  match machine_event_removed_id(probed) {
    Some(_) => fail("machine.probed must not look like a tombstone")
    None => ()
  }
  let removed = EventEnvelope::new(
    id="evt_2",
    org_id=ORG_LOCAL,
    event_type=EVENT_MACHINE_REMOVED,
    ts="2026-01-01T00:00:02Z",
    subject="machine/mch_test",
    seq=2L,
    payload=machine_removed_payload("mch_test"),
  )
  match machine_event_removed_id(removed) {
    Some(machine_id) => assert_eq(machine_id, "mch_test")
    None => fail("machine.removed payload lost the tombstone id")
  }
  match machine_event_record(removed) {
    Some(_) => fail("machine.removed must not carry a record snapshot")
    None => ()
  }
}
