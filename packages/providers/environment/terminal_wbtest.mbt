///|
test "terminal sanitizer consumes escape payloads instead of leaking them" {
  let text = "A\u{1b}[31mB\u{1b}[0mC\u{1b}]0;window-title\u{7}D\u{1b}7E"
  assert_eq(sanitize_terminal(text), "ABCDE")
  assert_eq(sanitize_terminal("plain\r\ntext\n"), "plain\n\ntext\n")
  assert_eq(
    sanitize_terminal("bell\u{7}back\u{8}space"),
    "bellbackspace",
  )
  // Unterminated control sequences swallow the rest of the chunk.
  assert_eq(sanitize_terminal("safe\u{1b}[31"), "safe")
}

///|
test "terminal argv wraps a typed command as one shell argument" {
  let identity = test_plan(
    "/home/dev",
    "/home/dev/work",
    "env_01ARYZ6S41",
  ).identity
  match terminal_argv(identity, "printf hello", "/workspace/project") {
    Ok(argv) => {
      assert_true(argv_has(argv, "exec"))
      assert_true(argv_has(argv, "-i"))
      assert_true(argv_has(argv, "-t"))
      assert_true(argv_has(argv, "sh"))
      assert_true(argv_has(argv, "-c"))
      assert_true(argv_has(argv, "printf hello"))
      // The container/tty argv never smuggles a combined docker command.
      assert_true(!call_has_element_containing(argv, "docker exec"))
    }
    Err(error) => fail("terminal argv failed: " + error.to_string())
  }
  match terminal_argv(identity, "", "/workspace/project") {
    Ok(argv) => {
      assert_true(argv_has(argv, "sh"))
      assert_true(argv_has(argv, "-i"))
    }
    Err(error) => fail("interactive argv failed: " + error.to_string())
  }
}
