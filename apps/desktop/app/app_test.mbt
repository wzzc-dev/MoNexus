///|
test "the shell renders the header and the Home page" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=920.0,
    height=560.0,
  )
  assert_true(harness.has_text("MoNexus"))
  assert_true(harness.has_text("Welcome to MoNexus"))
  assert_true(harness.has_text("host connecting"))
}

///|
test "all five pages can be switched by tapping navigation" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=920.0,
    height=560.0,
  )
  harness.tap_text("Machines")
  assert_true(harness.has_text("Machines page"))
  harness.tap_text("Tasks")
  assert_true(harness.has_text("Tasks page"))
  harness.tap_text("Search")
  assert_true(harness.has_text("Search page"))
  harness.tap_text("Settings")
  assert_true(harness.has_text("Settings page"))
  harness.tap_text("Home")
  assert_true(harness.has_text("Welcome to MoNexus"))
}

///|
test "host status and events are reflected in the model" {
  let model = Model::new()
  let online = update(
    model,
    LinkOnline({
      host_id: "host_test",
      version: "0.1.0-m1",
      ws_url: "ws://127.0.0.1:1234/ws",
      event_seq: 7L,
    }),
  )
  assert_eq(online.host.link.label(), "online")
  assert_eq(online.host.host_id, "host_test")
  assert_eq(online.host.event_seq, 7L)
  let arrived = update(online, EventArrived("host.heartbeat", 8L))
  assert_eq(arrived.host.event_count, 1)
  assert_eq(arrived.host.event_seq, 8L)
  let offline = update(arrived, LinkOffline("connection closed"))
  assert_eq(offline.host.link.label(), "offline")
  assert_eq(offline.host.last_error, "connection closed")
}

///|
test "page selection is stable across link updates" {
  let model = update(Model::new(), SelectPage(Settings))
  let online = update(
    model,
    LinkOnline({
      host_id: "host_test",
      version: "0.1.0-m1",
      ws_url: "ws://127.0.0.1:1234/ws",
      event_seq: 0L,
    }),
  )
  assert_eq(online.page.label(), "Settings")
  assert_eq(Model::new().page.label(), "Home")
}
