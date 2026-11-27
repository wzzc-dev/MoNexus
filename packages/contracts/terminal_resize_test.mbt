///|
test "terminal.resize params and result round-trip" {
  let params = terminal_resize_params("cid-resize", "term-1", 42, 132)
  let parsed_params = @json.parse(@json.Json::object(params).stringify())
  let object = match as_object(parsed_params) {
    Some(value) => value
    None => fail("terminal.resize params are not an object")
  }
  assert_eq(string_field(object, "client_request_id"), Some("cid-resize"))
  assert_eq(string_field(object, "session_id"), Some("term-1"))
  assert_eq(int_field(object, "rows"), Some(42))
  assert_eq(int_field(object, "cols"), Some(132))

  let result = terminal_resize_result("term-1", 42, 132)
  let parsed_result = @json.parse(result.stringify())
  match terminal_resize_from_json(parsed_result) {
    Some(value) => {
      assert_eq(value.session_id, "term-1")
      assert_eq(value.rows, 42)
      assert_eq(value.cols, 132)
    }
    None => fail("terminal.resize result did not decode")
  }
}

///|
test "terminal.resize rejects invalid dimensions" {
  assert_false(terminal_size_is_valid(0, 80))
  assert_false(terminal_size_is_valid(24, 0))
  assert_false(terminal_size_is_valid(-1, 80))
  assert_false(terminal_size_is_valid(24, -1))
  assert_false(terminal_size_is_valid(TERMINAL_MAX_SIZE + 1, 80))
  assert_false(terminal_size_is_valid(24, TERMINAL_MAX_SIZE + 1))
  assert_true(terminal_size_is_valid(1, 1))
  assert_true(terminal_size_is_valid(TERMINAL_MAX_SIZE, TERMINAL_MAX_SIZE))

  let invalid = json_object([
    ("session_id", json_string("term-1")),
    ("rows", json_int(0)),
    ("cols", json_int(80)),
  ])
  assert_true(terminal_resize_from_json(invalid) is None)
}
