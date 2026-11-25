///|
/// M6 durable poll parsing: dead panes are reported, exit markers win, and
/// the log tail is copied byte-for-byte (an empty log stays empty).
test "durable poll: dead pane, exit marker and exact log text" {
  let exited = parse_durable_poll("__ALIVE__\n__DEAD__0\n__EXIT__7\n__LOG__\nbuild failed\n")
  assert_true(exited.alive)
  assert_true(exited.dead)
  assert_eq(exited.dead_status, 0)
  assert_true(exited.exited)
  assert_eq(exited.exit_code, 7)
  assert_eq(exited.output, "build failed\n")

  let died = parse_durable_poll("__ALIVE__\n__DEAD__137\n__LOG__\n")
  assert_true(died.dead)
  assert_eq(died.dead_status, 137)
  assert_false(died.exited)
  assert_eq(died.output, "")

  let empty = parse_durable_poll("__ALIVE__\n__LOG__\n")
  assert_false(empty.dead)
  assert_eq(empty.output, "")

  let running = parse_durable_poll("__ALIVE__\n__LOG__\nstill running")
  assert_false(running.dead)
  assert_false(running.exited)
  assert_eq(running.output, "still running")
}

///|
/// A log line that looks like a marker must not change poll state once the
/// log section has started.
test "durable poll: log content cannot spoof markers" {
  let poll = parse_durable_poll("__ALIVE__\n__LOG__\n__DEAD__1\n__EXIT__0\n")
  assert_false(poll.dead)
  assert_false(poll.exited)
  assert_eq(poll.output, "__DEAD__1\n__EXIT__0\n")
}
