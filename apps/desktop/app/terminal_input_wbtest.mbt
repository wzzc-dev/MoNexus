///|
fn terminal_input_test_context(selection : @core.TextRange?) -> @core.ViewEventContext {
  {
    frame: @core.Rect::new(x=0.0, y=0.0, width=240.0, height=40.0),
    child_frames: [],
    event: @core.AppEvent::Keyboard(
      @core.KeyboardEvent::new(
        key="c",
        modifiers=@core.KeyModifiers::new(control=true),
      ),
    ),
    focused: true,
    state: {
      focused: true,
      hovered: false,
      pressed: false,
      selected: false,
      checked: false,
      expanded: false,
      disabled: false,
      slots: @core.ViewStateSlots::empty(),
    },
    text_control: {
      caret: 0,
      selection,
      text_selection_anchor: None,
      text_selection_origin: None,
      composition: None,
      composition_cursor: None,
      undo_stack: [],
      redo_stack: [],
      goal_column: None,
      reveal: None,
    },
    text_system: @core.TextSystem::fallback(),
    environment: @core.Environment::neutral(),
    style: @core.ViewStyle::empty(),
    now_ms: 0.0,
  }
}

///|
fn terminal_input_test_field() -> @core.View[Msg] {
  terminal_input_field(
    @views.text_field(
      "abc",
      on_input=fn(value) { ProjectTerminalInput(value) },
      width=240.0,
      height=40.0,
    ),
  )
}

///|
test "plain Ctrl+C reaches terminal input as Copy and interrupts when unselected" {
  let result = terminal_input_test_field().text_command_result(
    terminal_input_test_context(None),
    @core.CommandIntent::Copy,
  )
  assert_true(result.result.handled)
  assert_eq(result.messages.length(), 1)
  match result.messages[0] {
    ProjectTerminalStop => ()
    _ => fail("expected ProjectTerminalStop")
  }
}

///|
test "Ctrl+C with a real text selection still copies" {
  let result = terminal_input_test_field().text_command_result(
    terminal_input_test_context(Some(@core.TextRange::new(start=0, end=2))),
    @core.CommandIntent::Copy,
  )
  assert_true(result.result.handled)
  assert_eq(result.messages.length(), 0)
}

