///|
fn float_test_base_model() -> Model {
  @env.unset_env_var("MONEXUS_SCENE_FLOAT")
  Model::new()
}

///|
fn float_test_harness(model : Model) -> @test_support.WidgetHarness {
  @test_support.WidgetHarness::from_program(
    program=@moui.Program::new_with_environment(
      init=() => (model, @moui.Effect::none()),
      update=(current, msg) => (update(current, msg), @moui.Effect::none()),
      view=(model, environment) => view(model, environment),
    ),
    width=1280.0,
    height=800.0,
  )
}

///|
fn float_test_captured_harness(
  model : Model,
) -> (@test_support.WidgetHarness, Ref[Model]) {
  let cell : Ref[Model] = Ref(model)
  let harness = @test_support.WidgetHarness::from_program(
    program=@moui.Program::new_with_environment(
      init=() => (model, @moui.Effect::none()),
      update=(current, msg) => {
        let next = update(current, msg)
        cell.val = next
        (next, @moui.Effect::none())
      },
      view=(model, environment) => view(model, environment),
    ),
    width=1280.0,
    height=800.0,
  )
  (harness, cell)
}

///|
fn float_test_workspace_record() -> @contracts.WorkspaceRecord {
  {
    id: "wsp_float",
    machine_id: "",
    kind: "local",
    root: "/tmp/float-demo",
    name: "float-demo",
    git_root: "/tmp/float-demo",
    is_git: true,
    state: "open",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
}

///|
test "the Tools row toggles one overlay without changing the route" {
  let model = update(float_test_base_model(), SelectPage(Settings))
  let harness = float_test_harness(model)
  assert_true(harness.has_text("Workspace"))
  assert_true(harness.has_text("Connection"))
  assert_false(harness.has_text("Floating workspace"))
  harness.tap_text("Workspace")
  assert_true(harness.has_text("Floating workspace"))
  assert_true(harness.has_text("Connection"))
  let sidebar = match harness.text_frame("Workspace") {
    Some(frame) => frame
    None => fail("expected the sidebar Workspace row")
  }
  let title = match harness.text_frame("Floating workspace") {
    Some(frame) => frame
    None => fail("expected the overlay title")
  }
  assert_true(sidebar.origin.x + sidebar.size.width < 240.0)
  assert_true(title.origin.x >= 248.0)
  assert_true(title.origin.x + title.size.width <= 1280.0)
  assert_true(title.origin.y >= 56.0)
  assert_true(title.origin.y + title.size.height <= 800.0)
  harness.tap_text("Workspace")
  assert_false(harness.has_text("Floating workspace"))
  assert_true(harness.has_text("Connection"))
}

///|
test "closing the overlay keeps tabs, notes and geometry" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let model = update(model, FloatNoteContentDraft("local note body"))
  let model = update(model, FloatHeaderDrag(Started, 0.0, 0.0))
  let model = update(model, FloatHeaderDrag(Changed, 44.0, 28.0))
  let model = update(model, FloatHeaderDrag(Ended, 44.0, 28.0))
  let model = update(model, FloatResizeDrag(Started, 0.0, 0.0))
  let model = update(model, FloatResizeDrag(Changed, 60.0, 40.0))
  let model = update(model, FloatResizeDrag(Ended, 60.0, 40.0))
  let before_note = match float_active_note(model.float) {
    Some(note) => note
    None => fail("expected an active note")
  }
  let closed = update(model, ToggleFloatWorkspace)
  assert_false(closed.float.open)
  assert_eq(closed.float.x, model.float.x)
  assert_eq(closed.float.y, model.float.y)
  assert_eq(closed.float.width, model.float.width)
  assert_eq(closed.float.height, model.float.height)
  assert_eq(closed.float.active_tab, model.float.active_tab)
  assert_eq(closed.float.tabs.length(), model.float.tabs.length())
  match float_active_note(closed.float) {
    Some(note) => {
      assert_eq(note.id, before_note.id)
      assert_eq(note.content, "local note body")
      assert_eq(note.title, before_note.title)
    }
    None => fail("expected the same active note after close")
  }
  let reopened = update(closed, ToggleFloatWorkspace)
  assert_true(reopened.float.open)
  match float_active_note(reopened.float) {
    Some(note) => assert_eq(note.content, "local note body")
    None => fail("expected the same active note after reopen")
  }
}

///|
test "new notes append tabs and the last tab can close honestly" {
  let first = float_workspace_new(English)
  assert_eq(first.tabs.length(), 1)
  let second = float_new_note(first, English)
  assert_eq(second.tabs.length(), 2)
  assert_eq(second.active_tab, second.tabs[1].id)
  let third = float_new_note(second, English)
  assert_eq(third.tabs.length(), 3)
  assert_true(third.tabs[2].kind == FloatNote)
  let first_closed = float_close_tab(third, third.tabs[0].id)
  assert_eq(first_closed.tabs.length(), 2)
  let last_closed = float_close_tab(
    float_close_tab(first_closed, first_closed.tabs[0].id),
    first_closed.tabs[1].id,
  )
  assert_eq(last_closed.tabs.length(), 0)
  assert_eq(last_closed.active_tab, "")
  let fresh = float_new_note(last_closed, English)
  assert_eq(fresh.tabs.length(), 1)
  assert_true(fresh.tabs[0].kind == FloatNote)
}

///|
test "Agent and Terminal are single reusable tabs" {
  let workspace = float_workspace_new(English)
  let with_agent = float_new_kind_tab(workspace, FloatAgent)
  let agent_tab = with_agent.active_tab
  let with_agent_again = float_new_kind_tab(with_agent, FloatAgent)
  assert_eq(with_agent_again.active_tab, agent_tab)
  assert_eq(with_agent_again.tabs.length(), with_agent.tabs.length())
  let with_terminal = float_new_kind_tab(with_agent_again, FloatTerminal)
  let terminal_tab = with_terminal.active_tab
  let with_terminal_again = float_new_kind_tab(with_terminal, FloatTerminal)
  assert_eq(with_terminal_again.active_tab, terminal_tab)
  assert_eq(with_terminal_again.tabs.length(), with_terminal.tabs.length())
}

///|
test "note titles and file names cannot escape the notes directory" {
  assert_true(float_note_file_name("n1") is Some("note-n1.md"))
  assert_true(float_note_file_name("n_2-a") is Some("note-n_2-a.md"))
  assert_true(float_note_file_name("") is None)
  assert_true(float_note_file_name("..") is None)
  assert_true(float_note_file_name("n1/evil") is None)
  assert_true(float_note_file_name("n1\\evil") is None)
  assert_true(float_note_file_name("n1.md") is None)
  assert_true(float_note_path_in("/cfg/notes", "note-n1.md") is Some("/cfg/notes/note-n1.md"))
  assert_true(float_note_path_in("/cfg/notes", "") is None)
  assert_true(float_note_path_in("/cfg/notes", "..") is None)
  assert_true(float_note_path_in("/cfg/notes", "../note.md") is None)
  assert_true(float_note_path_in("/cfg/notes", "dir/note.md") is None)
  assert_true(float_note_path_in("/cfg/notes", "note.txt") is None)
  assert_true(float_note_title_problem("Weekly notes") is None)
  assert_true(float_note_title_problem("") is None)
  assert_true(float_note_title_problem("../secret") is Some(_))
  assert_true(float_note_title_problem("a/b") is Some(_))
  assert_true(float_note_title_problem("a\\b") is Some(_))
  assert_true(float_note_title_problem("line\nbreak") is Some(_))
  assert_true(
    float_note_title_problem(
      "x".repeat(121),
    ) is Some(_),
  )
}

///|
test "workspace index round-trips tabs and geometry" {
  let workspace = float_workspace_new(English)
  let workspace = float_new_note(workspace, English)
  let workspace = float_new_kind_tab(workspace, FloatAgent)
  let workspace = float_new_kind_tab(workspace, FloatTerminal)
  let workspace = {
    ..workspace,
    open: true,
    x: 400.0,
    y: 120.0,
    width: 712.0,
    height: 480.0,
    active_tab: "tab-agent",
  }
  let restore = match decode_float_workspace(encode_float_workspace(workspace)) {
    Some(value) => value
    None => fail("expected the written index to decode")
  }
  assert_true(restore.has_state)
  assert_eq(restore.x, 400.0)
  assert_eq(restore.y, 120.0)
  assert_eq(restore.width, 712.0)
  assert_eq(restore.height, 480.0)
  assert_eq(restore.active_tab, "tab-agent")
  assert_eq(restore.tabs.length(), 4)
  assert_eq(restore.notes.length(), 2)
  assert_true(restore.tabs[1].kind == FloatNote)
  assert_true(restore.tabs[2].kind == FloatAgent)
  assert_true(restore.tabs[3].kind == FloatTerminal)
  assert_true(decode_float_workspace("[]") is None)
  assert_true(decode_float_workspace("{\"schema_version\":2}") is None)
  let empty = match decode_float_workspace("{\"schema_version\":1}") {
    Some(value) => value
    None => fail("expected a schema-only index to decode as empty")
  }
  assert_eq(empty.tabs.length(), 0)
  assert_eq(empty.notes.length(), 0)
}

///|
test "drafts request local note writes and stale save results are ignored" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let model = update(model, FloatNoteContentDraft("first body"))
  let note = match float_active_note(model.float) {
    Some(value) => value
    None => fail("expected the default note")
  }
  assert_true(note.state is FloatNoteSaving)
  assert_eq(note.title, "Note 1")
  let requests = float_persist_requests(
    model.float,
    FloatNoteContentDraft("first body"),
  )
  assert_eq(requests.length(), 1)
  match requests[0] {
    FloatNoteRequest(write) => {
      assert_eq(write.note_id, note.id)
      assert_eq(write.file_name, "note-n1.md")
      assert_eq(write.content, "first body")
      assert_eq(write.revision, note.revision)
      assert_true(write.state_json.contains("\"schema_version\":1"))
    }
    _ => fail("expected a note write request")
  }
  let renamed = update(model, FloatNoteTitleDraft("Weekly review"))
  let renamed_note = match float_active_note(renamed.float) {
    Some(value) => value
    None => fail("expected the renamed note")
  }
  assert_eq(renamed_note.title, "Weekly review")
  assert_eq(renamed_note.file_name, "note-n1.md")
  let saved = update(
    renamed,
    FloatNoteStored(
      renamed_note.id,
      renamed_note.revision,
      true,
      "",
    ),
  )
  match float_active_note(saved.float) {
    Some(value) => assert_true(value.state is FloatNoteSaved)
    None => fail("expected the saved note")
  }
  let after = update(saved, FloatNoteContentDraft("second body"))
  let current = match float_active_note(after.float) {
    Some(value) => value
    None => fail("expected the newer note")
  }
  let stale = update(
    after,
    FloatNoteStored(renamed_note.id, renamed_note.revision, false, "stale"),
  )
  match float_active_note(stale.float) {
    Some(value) => assert_true(value.state is FloatNoteSaving)
    None => fail("expected the newer saving note")
  }
  let failed = update(
    after,
    FloatNoteStored(current.id, current.revision, false, "disk full"),
  )
  match float_active_note(failed.float) {
    Some(value) => assert_true(value.state is FloatNoteFailed(_))
    None => fail("expected the failed note")
  }
}

///|
test "drag and resize stay inside the fixed window" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let dragged = update(model, FloatHeaderDrag(Started, 0.0, 0.0))
  let dragged = update(dragged, FloatHeaderDrag(Changed, 5000.0, 5000.0))
  assert_eq(dragged.float.x, 368.0)
  assert_eq(dragged.float.y, 172.0)
  let dragged = update(dragged, FloatHeaderDrag(Ended, 5000.0, 5000.0))
  assert_false(dragged.float.dragging)
  let resized = update(model, FloatResizeDrag(Started, 0.0, 0.0))
  let resized = update(resized, FloatResizeDrag(Changed, 5000.0, 5000.0))
  assert_eq(resized.float.width, 1024.0)
  assert_eq(resized.float.height, 736.0)
  assert_eq(resized.float.x, 248.0)
  assert_eq(resized.float.y, 56.0)
  let resized = update(resized, FloatResizeDrag(Ended, 5000.0, 5000.0))
  assert_false(resized.float.resizing)
  let shrunk = update(model, FloatResizeDrag(Started, 0.0, 0.0))
  let shrunk = update(shrunk, FloatResizeDrag(Changed, -5000.0, -5000.0))
  assert_eq(shrunk.float.width, 480.0)
  assert_eq(shrunk.float.height, 340.0)
}

///|
async test "notes round-trip with mode 0600 and restore after restart" {
  let dir = @fs.tmpdir(prefix="monexus-float-note-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  let workspace = float_workspace_new(English)
  let workspace = float_new_note(workspace, English)
  let workspace = {
    ..workspace,
    open: true,
    x: 360.0,
    y: 120.0,
    width: 720.0,
    height: 460.0,
  }
  let note = match float_active_note(workspace) {
    Some(value) => value
    None => fail("expected the second note")
  }
  let path = match float_note_path_in(float_notes_dir_in(config), note.file_name) {
    Some(value) => value
    None => fail("expected a safe note path")
  }
  assert_true(
    write_float_note_in(config, note.file_name, "# local note\n\nkept") is Ok(_),
  )
  let first = match float_note_by_id(workspace, "n1") {
    Some(value) => value
    None => fail("expected the default note")
  }
  assert_true(
    write_float_note_in(config, first.file_name, "") is Ok(_),
  )
  assert_true(@fs.exists(path))
  assert_eq(theme_test_mode(path), "600")
  assert_false(@fs.exists(path + ".tmp"))
  assert_true(write_float_state_in(config, encode_float_workspace(workspace)) is Ok(_))
  assert_eq(theme_test_mode(float_state_path_in(config)), "600")
  let restore = read_float_restore_in(config)
  assert_true(restore.has_state)
  assert_eq(restore.x, 360.0)
  assert_eq(restore.y, 120.0)
  assert_eq(restore.width, 720.0)
  assert_eq(restore.height, 460.0)
  assert_eq(restore.notes.length(), 2)
  let mut found = false
  for restored in restore.notes {
    if restored.id == note.id {
      found = true
      assert_eq(restored.content, "# local note\n\nkept")
      assert_eq(restored.file_name, note.file_name)
    }
  }
  assert_true(found)
}

///|
async test "a missing index falls back to safe note filenames without collision" {
  let dir = @fs.tmpdir(prefix="monexus-float-fallback-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  assert_true(write_float_note_in(config, "note-n2.md", "existing note") is Ok(_))
  let restore = read_float_restore_in(config)
  assert_true(restore.has_state)
  assert_eq(restore.notes.length(), 1)
  assert_eq(restore.notes[0].file_name, "note-n2.md")
  assert_eq(restore.notes[0].content, "existing note")
  assert_eq(restore.tabs.length(), 1)
  assert_true(restore.next_id >= 3)
}

///|
test "the Browser menu row is disabled and creates no tab" {
  let base = float_test_base_model()
  let (harness, cell) = float_test_captured_harness(base)
  harness.tap_text("Workspace")
  assert_true(cell.val.float.open)
  let tabs_before = cell.val.float.tabs.length()
  harness.tap_text("+")
  assert_true(cell.val.float.menu_open)
  assert_true(harness.has_text("Browser · Later"))
  assert_true(harness.has_text("New note"))
  assert_true(harness.has_text("New Agent conversation"))
  assert_true(harness.has_text("New terminal"))
  harness.tap_text("Browser · Later")
  assert_eq(cell.val.float.tabs.length(), tabs_before)
  assert_true(cell.val.float.menu_open)
}

///|
test "the + menu creates tabs and tab close buttons remain interactive" {
  let (harness, cell) = float_test_captured_harness(float_test_base_model())
  harness.tap_text("Workspace")
  let note_count = cell.val.float.tabs.length()
  harness.tap_text("+")
  harness.tap_text("New note")
  assert_eq(cell.val.float.tabs.length(), note_count + 1)
  let active = match float_active_tab(cell.val.float) {
    Some(tab) => tab
    None => fail("expected the new note to become active")
  }
  assert_true(active.kind == FloatNote)
  harness.tap_text("+")
  harness.tap_text("New Agent conversation")
  let agent_tab = match float_active_tab(cell.val.float) {
    Some(tab) => tab
    None => fail("expected the Agent tab to become active")
  }
  assert_true(agent_tab.kind == FloatAgent)
  harness.tap_text("+")
  harness.tap_text("New terminal")
  let terminal_tab = match float_active_tab(cell.val.float) {
    Some(tab) => tab
    None => fail("expected the Terminal tab to become active")
  }
  assert_true(terminal_tab.kind == FloatTerminal)
  let tabs_before_close = cell.val.float.tabs.length()
  harness.tap_text("×")
  assert_eq(cell.val.float.tabs.length(), tabs_before_close - 1)
  assert_true(cell.val.float.open)
}

///|
test "Agent and Terminal tabs expose honest empty states" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let agent_model = update(model, FloatNewAgent)
  let agent_harness = float_test_harness(agent_model)
  assert_true(
    agent_harness.has_text(
      "No active Agent session. This tab reuses the current Bot and composer; send below to start the existing Agent path.",
    ),
  )
  assert_true(agent_harness.has_text("Start Chat"))
  assert_true(
    agent_harness.has_text(
      "Reply in this Agent conversation. Sending uses the current Bot.",
    ),
  )
  let terminal_model = update(agent_model, FloatNewTerminal)
  let terminal_harness = float_test_harness(terminal_model)
  assert_true(terminal_harness.has_text("no project"))
  assert_true(
    terminal_harness.has_text(
      "Open a project first, then open its terminal. This tab does not invent a second terminal backend.",
    ),
  )
}

///|
test "the overlay terminal reuses the focused PTY and stops polling when closed" {
  let base = update(float_test_base_model(), SelectPage(Settings))
  let base = update(base, ProjectOpened(float_test_workspace_record()))
  let base = update(base, ProjectTerminalOpened("sess_float", "$ ", 2L, false))
  assert_false(terminal_should_poll(base))
  let opened = update(base, ToggleFloatWorkspace)
  let opened = update(opened, FloatNewTerminal)
  assert_true(float_terminal_visible(opened))
  assert_true(opened.project.terminal_focus)
  assert_eq(opened.project.terminal_id, "sess_float")
  assert_true(terminal_should_poll(opened))
  let harness = float_test_harness(opened)
  assert_true(harness.has_text("shared PTY"))
  assert_true(harness.has_text("float-demo"))
  assert_true(harness.has_text("Send"))
  assert_true(harness.has_text("Stop"))
  let closed = update(opened, CloseFloatWorkspace)
  assert_false(float_terminal_visible(closed))
  assert_false(closed.project.terminal_focus)
  assert_false(terminal_should_poll(closed))
}

///|
test "overlay panes keep their controls inside the fixed panel" {
  let base = update(float_test_base_model(), SelectPage(Settings))
  let opened = update(base, ToggleFloatWorkspace)
  let agent = update(opened, FloatNewAgent)
  let agent_harness = float_test_harness(agent)
  let send = match agent_harness.text_frame("Send") {
    Some(frame) => frame
    None => fail("expected the Agent send button")
  }
  assert_true(send.origin.y + send.size.height <= 684.0)
  let base = update(base, ProjectOpened(float_test_workspace_record()))
  let base = update(base, ProjectTerminalOpened("sess_float", "$ ", 2L, false))
  let terminal = update(base, ToggleFloatWorkspace)
  let terminal = update(terminal, FloatNewTerminal)
  let terminal_harness = float_test_harness(terminal)
  let send = match terminal_harness.text_frame("Send") {
    Some(frame) => frame
    None => fail("expected the terminal send button")
  }
  assert_true(send.origin.y + send.size.height <= 684.0)
  assert_true(send.origin.x >= 248.0)
}

///|
test "floating Agent paints the selected P1 Chat and reuses its composer" {
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let detail = p1_chat_detail(
    "chat_a",
    "bot_a",
    "Plan the release",
    "",
    "agent_1",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let model = update(
    update(Model::new(), BotsLoaded([bot])),
    ChatsLoaded([detail]),
  )
  let (opened, _) = update_full(model, ChatOpened(detail))
  let (loaded, _) = update_full(
    opened,
    ChatMessagesLoaded(
      "chat_a",
      [
        p1_message(
          "msg_1",
          "chat_a",
          @contracts.CHAT_MESSAGE_ROLE_USER,
          "Draft the release notes",
        ),
        p1_message(
          "msg_2",
          "chat_a",
          @contracts.CHAT_MESSAGE_ROLE_ASSISTANT,
          "I will draft them.",
        ),
      ],
      "msg_2",
      false,
    ),
  )
  let read = @contracts.ChatReadResult::new(
    session_id="asn_chat_a",
    runtime_session_id="",
    cursor=0L,
    text="",
    state=@contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let (loaded, _) = update_full(loaded, ChatReadLoaded("chat_a", read))
  let away = update(loaded, SelectPage(Settings))
  let floating = update(update(away, ToggleFloatWorkspace), FloatNewAgent)
  assert_true(float_agent_visible(floating))
  assert_true(chat_should_poll(floating))
  let (_, poll_commands) = update_full(floating, ChatPoll)
  assert_eq(poll_commands.length(), 2)
  let harness = float_test_harness(floating)
  assert_true(harness.has_text("Plan the release"))
  assert_true(harness.has_text("Draft the release notes"))
  assert_true(harness.has_text("I will draft them."))
  assert_true(harness.has_text("Stop"))
  let (drafted, _) = update_full(floating, AgentInputDraft("  ship it  "))
  let (_, commands) = update_full(drafted, ComposerSend)
  assert_eq(commands.length(), 1)
  match commands[0] {
    ChatSend(chat_id, prompt) => {
      assert_eq(chat_id, "chat_a")
      assert_eq(prompt, "ship it")
    }
    _ => fail("expected chat.send from the floating Agent composer")
  }
  assert_false(chat_should_poll(update(floating, CloseFloatWorkspace)))
}
