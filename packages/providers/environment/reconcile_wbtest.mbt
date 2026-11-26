///|
test "reconcile adopts a complete timed-out create and destroys an incomplete one" {
  let creating = test_record(@contracts.ENVIRONMENT_STATE_CREATING)
  // A running container from a timed-out create is adopted, never recreated.
  assert_true(
    reconcile_decision(creating, Some(test_inspect(true)), true, true) is Adopt,
  )
  // A non-running container from a timed-out create is destroyed.
  assert_true(
    reconcile_decision(creating, Some(test_inspect(false)), true, true)
    is DestroyIntent,
  )
  // Without a container the intent settles as drift/failure; it is never
  // treated as a successful environment.
  match reconcile_decision(creating, None, false, true) {
    MarkDrift(message) => assert_true(message.contains("timed-out create"))
    _ => fail("a missing create intent must be drift")
  }
  // A live record whose container disappeared is drift.
  let running = test_record(@contracts.ENVIRONMENT_STATE_RUNNING)
  match reconcile_decision(running, None, false, false) {
    MarkDrift(message) => assert_true(message.contains("missing"))
    _ => fail("a missing running container must be drift")
  }
  // Destroyed and failed records are terminal for reconcile.
  assert_true(
    reconcile_decision(
      test_record(@contracts.ENVIRONMENT_STATE_DESTROYED),
      None,
      false,
      false,
    ) is Ignore,
  )
  assert_true(
    reconcile_decision(
      test_record(@contracts.ENVIRONMENT_STATE_FAILED),
      None,
      false,
      false,
    ) is Ignore,
  )
}

///|
test "reconcile never adopts or removes a container with mismatched labels" {
  let running = test_record(@contracts.ENVIRONMENT_STATE_RUNNING)
  match reconcile_decision(running, Some(test_inspect(true)), false, false) {
    MarkDrift(message) => assert_true(message.contains("left untouched"))
    _ => fail("a foreign container must be drift, never adopt or destroy")
  }
  let creating = test_record(@contracts.ENVIRONMENT_STATE_CREATING)
  match reconcile_decision(creating, Some(test_inspect(false)), false, true) {
    MarkDrift(message) => assert_true(message.contains("left untouched"))
    _ => fail("a foreign container must never be destroyed")
  }
  assert_true(managed_name_matches(running, "monexus-env-env_01ARYZ6S41"))
  assert_true(!managed_name_matches(running, "env_01ARYZ6S41"))
  assert_true(create_intent_timed_out(CREATE_INTENT_TIMEOUT_MS))
  assert_true(!create_intent_timed_out(CREATE_INTENT_TIMEOUT_MS - 1L))
}
