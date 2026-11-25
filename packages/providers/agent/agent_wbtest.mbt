///|
/// ADR-0011: ssh exit 255, an unobservable status and a signal death of the
/// local client all mean the transport was lost.
test "remote EOF maps 255, signals and unknown to lost" {
  assert_eq(remote_eof_stop_reason(None), "lost")
  assert_eq(remote_eof_stop_reason(Some(255)), "lost")
  assert_eq(remote_eof_stop_reason(Some(-9)), "lost")
  assert_eq(remote_eof_stop_reason(Some(-15)), "lost")
}

///|
/// ADR-0011: any other observed exit code is the remote agent exiting
/// mid-turn.
test "remote EOF maps other exit codes to interrupted" {
  assert_eq(remote_eof_stop_reason(Some(0)), "interrupted")
  assert_eq(remote_eof_stop_reason(Some(1)), "interrupted")
  assert_eq(remote_eof_stop_reason(Some(3)), "interrupted")
}

///|
/// The readable error is stable, free of paths/credentials and only set for
/// the two remote failure classes.
test "remote EOF last_error is readable and bounded" {
  assert_eq(remote_eof_last_error("lost"), "remote agent connection lost")
  assert_eq(remote_eof_last_error("interrupted"), "remote agent exited mid-turn")
  assert_eq(remote_eof_last_error("exited"), "")
  assert_eq(remote_eof_last_error("cancelled"), "")
}
