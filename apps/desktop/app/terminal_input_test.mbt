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
test "runtime focus on the terminal input turns plain Ctrl+C into a stop message" {
  let saw_stop : Ref[Bool] = Ref(false)
  let harness = terminal_input_runtime_harness(
    terminal_input_runtime_model(""),
    saw_stop,
  )
  harness.tap_text("type a command, Enter sends")
  ignore(harness.runtime().dispatch_command(@core.CommandIntent::Copy))
  assert_true(saw_stop.val)
}

///|
test "runtime focus with a select-all still lets Ctrl+C copy" {
  let saw_stop : Ref[Bool] = Ref(false)
  let harness = terminal_input_runtime_harness(
    terminal_input_runtime_model("echo hi"),
    saw_stop,
  )
  harness.tap_text("echo hi")
  assert_true(harness.runtime().select_focused_text_all())
  ignore(harness.runtime().dispatch_command(@core.CommandIntent::Copy))
  assert_false(saw_stop.val)
}
