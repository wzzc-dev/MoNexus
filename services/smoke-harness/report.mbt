///|
/// PASS/FAIL/SKIP accounting for the native smoke harness. This mirrors the
/// shell script's summary contract so CI parsers do not need a second format.
struct Report {
  mut passed : Int
  mut failed : Int
  mut skipped : Int
}

///|
fn Report::new() -> Report {
  { passed: 0, failed: 0, skipped: 0 }
}

///|
fn Report::pass(self : Report, label : String) -> Unit {
  self.passed = self.passed + 1
  println("PASS  " + label)
}

///|
fn Report::fail(self : Report, label : String, detail : String) -> Unit {
  self.failed = self.failed + 1
  println("FAIL  " + label)
  if detail != "" {
    eprintln("--- output ---")
    eprintln(detail)
    eprintln("--------------")
  }
}

///|
fn Report::skip(self : Report, label : String) -> Unit {
  self.skipped = self.skipped + 1
  println("SKIP  " + label)
}

///|
fn Report::eq(
  self : Report,
  label : String,
  expected : String,
  actual : String,
) -> Unit {
  if expected == actual {
    self.pass(label)
  } else {
    self.fail(label + " (expected: " + expected + ")", actual)
  }
}

///|
fn Report::contains(
  self : Report,
  label : String,
  needle : String,
  haystack : String,
) -> Unit {
  if haystack.contains(needle) {
    self.pass(label)
  } else {
    self.fail(label + " (missing: " + needle + ")", haystack)
  }
}

///|
fn Report::not_contains(
  self : Report,
  label : String,
  needle : String,
  haystack : String,
) -> Unit {
  if haystack.contains(needle) {
    self.fail(label + " (unexpected: " + needle + ")", haystack)
  } else {
    self.pass(label)
  }
}

///|
fn Report::summary(self : Report) -> Unit {
  println(
    "\nSUMMARY  passed=" +
    self.passed.to_string() +
    " failed=" +
    self.failed.to_string() +
    " skipped=" +
    self.skipped.to_string(),
  )
}

///|
fn Report::ok(self : Report) -> Bool {
  self.failed == 0
}
