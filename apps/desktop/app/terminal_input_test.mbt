///|
fn terminal_input_runtime_model(input : String) -> Model {
  let record : @contracts.WorkspaceRecord = {
    id: "wsp_test",
    machine_id: "",
    kind: "local",
    root: "/tmp/demo",
    name: "demo",
    git_root: "/tmp/demo",
    is_git: true,
    state: "open",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
  let model = update(Model::new(), SelectPage(Manage))
  let model = update(model, ProjectOpened(record))
  let model = update(model, ProjectTerminalFocus)
  let model = update(model, ProjectTerminalOpened("sess_test", "$ ", 2L, false))
  update(model, ProjectTerminalInput(input))
}

///|
fn terminal_input_runtime_harness(
  model : Model,
  saw_stop : Ref[Bool],
) -> @test_support.WidgetHarness {
  @test_support.WidgetHarness::from_program(
    program=@moui.Program::new(
      init=() => (model, @moui.Effect::none()),
      update=(current, msg) => {
        match msg {
          @app.ProjectTerminalStop => saw_stop.val = true
          _ => ()
        }
        (update(current, msg), @moui.Effect::none())
      },
      view~,
    ),
    width=1280.0,
    height=800.0,
  )
}

///|
fn terminal_input_key(
  key : String,
  modifiers : @core.KeyModifiers,
) -> @core.KeyboardEvent {
  @core.KeyboardEvent::new(key~, modifiers~)
}

///|
fn terminal_input_clipboard_bridge(
  clipboard : Ref[String],
) -> @backend_host.HostServiceBridge {
  @backend_host.HostServiceBridge::new(
    capabilities=@backend_host.HostServiceCapabilities::new(clipboard=true),
    handle=request => {
      match request {
        @backend_host.Clipboard(@backend_host.WriteText(value)) => {
          clipboard.val = value
          @backend_host.ClipboardWritten
        }
        @backend_host.Clipboard(@backend_host.ReadText) =>
          @backend_host.ClipboardText(clipboard.val)
        _ => @backend_host.Unavailable("unexpected request")
      }
    },
  )
}

///|
test "runtime focus turns Interrupt into a stop on the focused project terminal" {
  let saw_stop : Ref[Bool] = Ref(false)
  let harness = terminal_input_runtime_harness(
    terminal_input_runtime_model("echo hi"),
    saw_stop,
  )
  harness.tap_text("echo hi")
  ignore(harness.runtime().dispatch_command(@core.CommandIntent::Interrupt))
  assert_true(saw_stop.val)
}

///|
test "runtime copy without and with a selection never stops the terminal" {
  let saw_stop : Ref[Bool] = Ref(false)
  let harness = terminal_input_runtime_harness(
    terminal_input_runtime_model("echo hi"),
    saw_stop,
  )
  harness.tap_text("echo hi")
  ignore(harness.runtime().dispatch_command(@core.CommandIntent::Copy))
  assert_false(saw_stop.val)
  assert_true(harness.runtime().select_focused_text_all())
  ignore(harness.runtime().dispatch_command(@core.CommandIntent::Copy))
  assert_false(saw_stop.val)
}

///|
test "host chords interrupt on Ctrl+C and copy on every copy shortcut" {
  let saw_stop : Ref[Bool] = Ref(false)
  let harness = terminal_input_runtime_harness(
    terminal_input_runtime_model("echo hi"),
    saw_stop,
  )
  harness.tap_text("echo hi")
  let driver = @apphost.HostRuntimeDriver::new(
    runtime=harness.runtime(),
    schedule_redraw=() => (),
  )
  let clipboard : Ref[String] = Ref("unchanged")
  let bridge = terminal_input_clipboard_bridge(clipboard)
  let control = @core.KeyModifiers::new(control=true)
  let shifted_control = @core.KeyModifiers::new(control=true, shift=true)
  let meta = @core.KeyModifiers::new(meta=true)
  assert_eq(
    driver.keyboard_command_intent(terminal_input_key("c", control)),
    Some(@core.Interrupt),
  )
  assert_eq(
    driver.keyboard_command_intent(terminal_input_key("c", meta)),
    Some(@core.Copy),
  )
  assert_eq(
    driver.keyboard_command_intent(terminal_input_key("c", shifted_control)),
    Some(@core.Copy),
  )
  assert_eq(
    driver.keyboard_command_intent(terminal_input_key("Insert", control)),
    Some(@core.Copy),
  )
  ignore(
    driver.dispatch_keyboard_with_services(
      terminal_input_key("c", control),
      bridge,
    ),
  )
  assert_true(saw_stop.val)
  saw_stop.val = false
  ignore(
    driver.dispatch_keyboard_with_services(
      terminal_input_key("c", meta),
      bridge,
    ),
  )
  assert_false(saw_stop.val)
  assert_eq(clipboard.val, "")
  ignore(
    driver.dispatch_keyboard_with_services(
      terminal_input_key("c", shifted_control),
      bridge,
    ),
  )
  assert_false(saw_stop.val)
  assert_eq(clipboard.val, "")
  ignore(
    driver.dispatch_keyboard_with_services(
      terminal_input_key("Insert", control),
      bridge,
    ),
  )
  assert_false(saw_stop.val)
  assert_eq(clipboard.val, "")
  assert_true(harness.runtime().select_focused_text_all())
  ignore(
    driver.dispatch_keyboard_with_services(
      terminal_input_key("c", meta),
      bridge,
    ),
  )
  assert_false(saw_stop.val)
  assert_eq(clipboard.val, "echo hi")
  ignore(
    driver.dispatch_keyboard_with_services(
      terminal_input_key("c", shifted_control),
      bridge,
    ),
  )
  assert_false(saw_stop.val)
  assert_eq(clipboard.val, "echo hi")
}

///|
test "Interrupt stops the terminal from the floating terminal surface" {
  let saw_stop : Ref[Bool] = Ref(false)
  let model = update(terminal_input_runtime_model("echo hi"), SelectPage(Settings))
  let model = update(model, ToggleFloatWorkspace)
  let model = update(model, FloatNewTerminal)
  assert_true(float_terminal_visible(model))
  assert_true(terminal_surface_focused(model))
  let mut interrupt_bound = false
  for command in program().runtime_commands(model) {
    if command.command().intent == @core.Interrupt {
      match command.message() {
        ProjectTerminalStop => interrupt_bound = true
        _ => ()
      }
    }
  }
  assert_true(interrupt_bound)
  let harness = terminal_input_runtime_harness(model, saw_stop)
  harness.tap_text("echo hi")
  ignore(harness.runtime().dispatch_command(@core.CommandIntent::Interrupt))
  assert_true(saw_stop.val)
}

///|
test "focused project terminal binds Interrupt without a Ctrl+Shift+C interrupt" {
  let model = terminal_input_runtime_model("echo hi")
  let commands = program().runtime_commands(model)
  let mut interrupt_bound = false
  let mut copy_chord_interrupt = false
  for command in commands {
    let action = command.command()
    if action.intent == @core.Interrupt {
      interrupt_bound = true
      match command.message() {
        ProjectTerminalStop => ()
        _ => fail("Interrupt must send ProjectTerminalStop")
      }
    }
    match action.shortcut {
      Some(shortcut) =>
        if shortcut.modifiers.control &&
          shortcut.modifiers.shift &&
          (shortcut.key == "c" || shortcut.key == "C") {
          copy_chord_interrupt = true
        }
      None => ()
    }
  }
  assert_true(interrupt_bound)
  assert_false(copy_chord_interrupt)
}
