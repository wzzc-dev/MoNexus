///|
test "shell text trims only trailing newlines" {
  assert_eq(shell_text("hello\n"), "hello")
  assert_eq(shell_text("hello\n\n"), "hello")
  assert_eq(shell_text(" hello "), " hello ")
  assert_eq(shell_text("hello"), "hello")
}

///|
test "size lines use the last marker match" {
  let text = "TMUX_SIZE_BEFORE 23 80\nnoise\nTMUX_SIZE_BEFORE 29 100\n"
  match last_size_in(text, "TMUX_SIZE_BEFORE") {
    Some((rows, cols)) => {
      assert_eq(rows, 29)
      assert_eq(cols, 100)
    }
    None => fail("expected a size line")
  }
}

///|
test "size lines reject missing or malformed values" {
  assert_eq(last_size_in("TMUX_SIZE_BEFORE 23\n", "TMUX_SIZE_BEFORE"), None)
  assert_eq(last_size_in("other 23 80\n", "TMUX_SIZE_BEFORE"), None)
}
