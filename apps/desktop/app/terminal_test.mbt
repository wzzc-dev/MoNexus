///|
fn terminal_ui_test_record() -> @contracts.WorkspaceRecord {
  {
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
}

///|
test "the focused terminal draws its controls and workspace context" {
  let model = update(Model::new(), SelectPage(Manage))
  let model = update(model, ProjectOpened(terminal_ui_test_record()))
  let model = update(model, ProjectTerminalFocus)
  let model = update(model, ProjectTerminalOpened("sess_test", "$ ", 2L, false))
  let model = update(
    model,
    ProjectTerminalOutput("sess_test", 7L, "ok\n$ ", false),
  )
  let harness = @test_support.WidgetHarness::from_program(
    program=@moui.Program::new(
      init=() => (model, @moui.Effect::none()),
      update=(current, msg) => (update(current, msg), @moui.Effect::none()),
      view~,
    ),
    width=1280.0,
    height=800.0,
  )
  assert_true(harness.has_text("Terminal"))
  assert_true(harness.has_text("Back to projects"))
  assert_true(harness.has_text("demo"))
  assert_true(harness.has_text("/tmp/demo"))
  assert_true(harness.has_text("session sess_test"))
  assert_true(harness.has_text("running"))
  assert_true(harness.has_text("$"))
  assert_true(
    harness.has_text(
      "Enter sends · Ctrl+C, Ctrl+Shift+C or Stop interrupts",
    ),
  )
  assert_true(harness.has_text("Send"))
  assert_true(harness.has_text("Stop"))
  assert_true(harness.has_text("Clear"))
  assert_true(harness.has_text("Close"))
}
