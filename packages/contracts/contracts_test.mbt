///|
test "ulid time prefix matches the ULID specification example" {
  assert_eq(encode_ulid_time(1_469_918_176_385), "01ARYZ6S41")
  assert_eq(encode_ulid_time(0), "0000000000")
}

///|
test "new_ulid is 26 characters and starts with the encoded time" {
  let id = new_ulid(0)
  assert_eq(id.length(), 26)
  assert_eq(id[:10].to_owned(), "0000000000")
  assert_eq(new_id("evt", 0).has_prefix("evt_"), true)
}

///|
test "rfc3339 formatting is UTC with milliseconds" {
  assert_eq(format_rfc3339(0), "1970-01-01T00:00:00.000Z")
  assert_eq(format_rfc3339(1_700_000_000_123), "2023-11-14T22:13:20.123Z")
  assert_eq(format_rfc3339(1_709_164_800_000), "2024-02-29T00:00:00.000Z")
}

///|
test "rpc request round-trips and carries client_request_id" {
  let params = status_params("cid-1")
  let request = RpcRequest::new("r1", METHOD_HOST_STATUS, params)
  let parsed = @json.parse(request.to_json().stringify())
  match parse_request(parsed) {
    Ok(value) => {
      assert_eq(value.id, "r1")
      assert_eq(value.method, METHOD_HOST_STATUS)
      assert_eq(client_request_id(value.params), Some("cid-1"))
    }
    Err(message) => fail("parse_request failed: " + message)
  }
}

///|
test "rpc notifications and error responses decode" {
  let notification = RpcNotification::new(
    NOTIFICATION_EVENTS_EVENT,
    Map([("seq", json_int64(7))]),
  )
  let parsed = @json.parse(notification.to_json().stringify())
  assert_eq(is_notification(parsed), true)
  match parse_notification(parsed) {
    Ok(value) => assert_eq(value.method, NOTIFICATION_EVENTS_EVENT)
    Err(message) => fail("parse_notification failed: " + message)
  }
  let error = RpcError::new(ERR_INVALID_PARAMS, "bad params")
  let response = RpcResponse::to_json({
    id: "r2",
    result: None,
    error: Some(error),
  })
  match parse_response(@json.parse(response.stringify())) {
    Ok(value) =>
      match value.error {
        Some(found) => {
          assert_eq(found.code, ERR_INVALID_PARAMS)
          assert_eq(found.message, "bad params")
        }
        None => fail("expected an error response")
      }
    Err(message) => fail("parse_response failed: " + message)
  }
}

///|
test "event envelope round-trips" {
  let event = EventEnvelope::new(
    id="evt_01H",
    org_id=ORG_LOCAL,
    event_type=EVENT_HOST_HEARTBEAT,
    ts="2026-11-25T00:00:00.000Z",
    subject="host:host_01H",
    seq=42,
    payload=json_object([("uptime_ms", json_int64(1000))]),
    causation_id="cause-1",
    correlation_id="corr-1",
    idempotency_key="idem-1",
  )
  let parsed = EventEnvelope::from_json(
    @json.parse(event.to_json().stringify()),
  )
  match parsed {
    Some(value) => {
      assert_eq(value.id, "evt_01H")
      assert_eq(value.event_type, EVENT_HOST_HEARTBEAT)
      assert_eq(value.seq, 42)
      assert_eq(value.subject, "host:host_01H")
      assert_eq(value.causation_id, "cause-1")
    }
    None => fail("event envelope did not decode")
  }
}

///|
test "host discovery round-trips" {
  let info : HostInfo = {
    schema_version: DISCOVERY_SCHEMA_VERSION,
    host_id: "host_01H",
    version: "0.1.0-m1",
    pid: 123,
    port: 4567,
    token: "secret-token",
    ws_url: "ws://127.0.0.1:4567/ws",
    started_at: "2026-11-25T00:00:00.000Z",
    state_dir: "/tmp/monexus",
  }
  let parsed = HostInfo::from_json(@json.parse(info.to_json().stringify()))
  match parsed {
    Some(value) => {
      assert_eq(value.host_id, "host_01H")
      assert_eq(value.port, 4567)
      assert_eq(value.ws_url, "ws://127.0.0.1:4567/ws")
      assert_eq(value.token, "secret-token")
    }
    None => fail("host info did not decode")
  }
}

///|
test "host status and subscribe results round-trip" {
  let status : HostStatus = {
    host_id: "host_01H",
    version: "0.1.0-m1",
    status: HOST_STATUS_ONLINE,
    pid: 7,
    started_at: "2026-11-25T00:00:00.000Z",
    uptime_ms: 1234,
    event_seq: 9,
    state_dir: "/tmp/state",
    protocol_version: 1,
  }
  match HostStatus::from_json(@json.parse(status.to_json().stringify())) {
    Some(value) => {
      assert_eq(value.status, HOST_STATUS_ONLINE)
      assert_eq(value.event_seq, 9)
    }
    None => fail("host status did not decode")
  }
  let subscribe : SubscribeResult = {
    subscribed: true,
    replayed: 2,
    from_seq: 5,
    next_seq: 9,
  }
  match SubscribeResult::from_json(
    @json.parse(subscribe.to_json().stringify()),
  ) {
    Some(value) => assert_eq(value.replayed, 2)
    None => fail("subscribe result did not decode")
  }
}

///|
test "new ids are unique within one millisecond" {
  let unique : Array[String] = []
  for _ in 0..<200 {
    let id = new_id("evt", 1_234L)
    let mut duplicate = false
    for existing in unique {
      if existing == id {
        duplicate = true
        break
      }
    }
    if !duplicate {
      unique.push(id)
    }
  }
  assert_eq(unique.length(), 200)
}

///|
test "workspace params use the wire target and local default" {
  let remote = workspace_open_params("cid", "mch_1", "/tmp/project")
  assert_eq(workspace_open_target(remote), "mch_1")
  let local = workspace_open_params("cid", "", "/tmp/project")
  assert_eq(workspace_open_target(local), "")
  match workspace_root_param(local) {
    Ok(root) => assert_eq(root, "/tmp/project")
    Err(message) => fail("workspace_root_param failed: " + message)
  }
}

///|
test "workspace conflict errors read as Conflict" {
  let error = workspace_error(
    WORKSPACE_ERR_CONFLICT,
    "worktree is leased by an active run",
  )
  assert_eq(
    machine_error_text(error),
    "Conflict: worktree is leased by an active run",
  )
}

///|
test "workspace git params carry an optional worktree id" {
  let status = workspace_git_status_params(
    "cid",
    "wsp_1",
    worktree_id="wt_1",
  )
  assert_eq(string_field_or(status, "workspace_id", ""), "wsp_1")
  assert_eq(string_field_or(status, "worktree_id", ""), "wt_1")
  let diff = workspace_git_diff_params(
    "cid",
    "wsp_1",
    "src/main.mbt",
    false,
    "",
    worktree_id="wt_1",
  )
  assert_eq(string_field_or(diff, "path", ""), "src/main.mbt")
  assert_eq(string_field_or(diff, "worktree_id", ""), "wt_1")
  assert_eq(
    string_field_or(
      workspace_git_status_params("cid", "wsp_1"),
      "worktree_id",
      "",
    ),
    "",
  )
  let unsupported = workspace_error(
    WORKSPACE_ERR_UNSUPPORTED,
    "worktree git review is unsupported for environment-backed workspaces",
  )
  assert_true(unsupported.message.has_prefix("Unsupported: "))
}
