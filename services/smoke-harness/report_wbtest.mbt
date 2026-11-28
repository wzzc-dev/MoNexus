///|
test "report keeps pass fail skip counters" {
  let report = Report::new()
  report.pass("one")
  report.fail("two", "detail")
  report.skip("three")
  assert_eq(report.passed, 1)
  assert_eq(report.failed, 1)
  assert_eq(report.skipped, 1)
  assert_false(report.ok())
}

///|
test "report equality and containment assertions" {
  let report = Report::new()
  report.eq("equal", "same", "same")
  report.contains("contains", "needle", "hay needle")
  report.not_contains("not contains", "absent", "hay needle")
  assert_eq(report.passed, 3)
  assert_eq(report.failed, 0)
  assert_true(report.ok())
}
