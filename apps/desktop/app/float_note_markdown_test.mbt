///|
fn float_test_note(
  content~ : String,
  selection~ : @richtext.MarkdownEditorSelection = {
    caret: 0,
    selection: None,
  },
) -> @app.FloatNote {
  let note = @app.float_note_make(
    "n1",
    "Note 1",
    "note-n1.md",
    content,
    @app.FloatNoteSaved,
    0,
  )
  @app.float_note_set_selection(note, selection.caret, selection.selection)
}

///|
fn float_test_active_note(model : Model) -> @app.FloatNote raise {
  match @app.float_active_note(model.float) {
    Some(note) => note
    None => fail("expected an active note")
  }
}

///|
fn float_test_captured_program_harness(
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
    ).with_commands(commands=model => @app.float_note_formatting_commands(model)),
    width=1280.0,
    height=800.0,
  )
  (harness, cell)
}

///|
test "markdown notes preserve the canonical source through the rich session" {
  let source = "# 标题\n\n**粗体** *斜体* ~~删除~~ `代码` [链接](https://example.com)\n\n- 项目\n\n1. 有序\n\n> 引用\n\n```moonbit\nlet x = 1\n```\n\n---\n\n<div>raw html</div>\n\n[^1]: 脚注\n\n| 列 | 值 |\n| --- | --- |\n| a | b |"
  let note = float_test_note(content=source)
  assert_eq(note.session.source(), source)
  assert_eq(@richtext.parse_markdown(source).length() > 0, true)
  let result = @richtext.markdown_editor_apply_command_at(
    source,
    @richtext.MarkdownEditorCommand::Italic,
    Some({
      caret: 4,
      selection: Some(@core.TextRange::new(start=2, end=4)),
    }),
  )
  let transaction = @richtext.MarkdownEditTransaction::from_edit_result(
    source,
    result,
    reason=@richtext.CommandEdit,
  )
  let edited = float_note_apply_edit(note, transaction)
  assert_eq(edited.content, edited.session.source())
  assert_true(edited.content.contains("*标题*"))
  assert_true(edited.content.contains("<div>raw html</div>"))
  assert_true(edited.content.contains("[^1]: 脚注"))
  assert_true(edited.content.contains("| 列 | 值 |"))
}

///|
test "toolbar commands wrap text and turn lines into headings and lists" {
  let selected = float_test_note(
    content="正文",
    selection={ caret: 2, selection: Some(@core.TextRange::new(start=0, end=2)) },
  )
  let bold = float_note_apply_command(
    selected,
    @richtext.MarkdownEditorCommand::Bold,
  )
  assert_eq(bold.content, "**正文**")
  match bold.selection.selection {
    Some(range) => {
      assert_eq(range.start, 2)
      assert_eq(range.end, 4)
    }
    None => fail("expected the bold text to remain selected")
  }
  let heading = float_note_apply_command(
    float_test_note(content="标题"),
    @richtext.MarkdownEditorCommand::Heading(2),
  )
  assert_true(heading.content.has_prefix("## 标题"))
  let bullet = float_note_apply_command(
    float_test_note(content="项目"),
    @richtext.MarkdownEditorCommand::BulletList,
  )
  assert_true(bullet.content.contains("- 项目"))
  let ordered = float_note_apply_command(
    float_test_note(content="事项"),
    @richtext.MarkdownEditorCommand::OrderedList,
  )
  assert_true(ordered.content.contains("1. 事项"))
  assert_true(bold.state is FloatNoteSaving)
  assert_eq(bold.revision, 1)
}

///|
test "source mode changes presentation without changing note content" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let model = update(model, @app.FloatNoteContentDraft("# 标题\n\n正文"))
  let before = float_test_active_note(model)
  let source_model = update(model, @app.FloatNoteSourceMode(before.id, true))
  let source_note = float_test_active_note(source_model)
  assert_true(source_note.source_mode)
  assert_eq(source_note.content, before.content)
  assert_eq(source_note.session.source(), before.session.source())
  assert_eq(source_note.revision, before.revision)
  assert_true(source_note.state is @app.FloatNoteSaving)
  assert_true(before.state is @app.FloatNoteSaving)
  let formatted_model = update(
    source_model,
    @app.FloatNoteSourceMode(before.id, false),
  )
  let formatted_note = float_test_active_note(formatted_model)
  assert_false(formatted_note.source_mode)
  assert_eq(formatted_note.content, before.content)
  assert_eq(formatted_note.revision, before.revision)
}

///|
test "typing and formatting edits request debounced note autosave" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let note = float_test_active_note(model)
  let typed : @richtext.MarkdownEditTransaction = {
    previous_source: "",
    source: "正文",
    edit_range: { start: 0, end: 0 },
    replacement: "正文",
    deleted: "",
    caret: 2,
    selection: None,
    reason: @richtext.TextInput,
  }
  let typed_model = update(model, @app.FloatNoteEdit(note.id, typed))
  let typed_note = float_test_active_note(typed_model)
  assert_eq(typed_note.content, "正文")
  assert_true(typed_note.state is FloatNoteSaving)
  let typed_requests = float_persist_requests(
    typed_model.float,
    @app.FloatNoteEdit(note.id, typed),
  )
  assert_eq(typed_requests.length(), 1)
  match typed_requests[0] {
    FloatNoteRequest(write) => {
      assert_eq(write.note_id, note.id)
      assert_eq(write.file_name, "note-n1.md")
      assert_eq(write.content, "正文")
      assert_eq(write.revision, typed_note.revision)
    }
    _ => fail("expected a note write for typed text")
  }
  let command = @app.FloatNoteCommand(
    note.id,
    @richtext.MarkdownEditorCommand::Bold,
  )
  let command_model = update(
    typed_model,
    @app.FloatNoteSelection(
      note.id,
      2,
      Some(@core.TextRange::new(start=0, end=2)),
    ),
  )
  let command_model = update(command_model, command)
  let command_note = float_test_active_note(command_model)
  assert_eq(command_note.content, "**正文**")
  assert_true(command_note.state is FloatNoteSaving)
  let command_requests = float_persist_requests(command_model.float, command)
  assert_eq(command_requests.length(), 1)
  match command_requests[0] {
    FloatNoteRequest(write) => {
      assert_eq(write.content, "**正文**")
      assert_eq(write.revision, command_note.revision)
    }
    _ => fail("expected a note write for a formatting command")
  }
}

///|
test "empty notes and multiple tabs keep independent rich sessions" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let first = float_test_active_note(model)
  assert_eq(first.content, "")
  assert_eq(first.session.source(), "")
  let harness = float_test_harness(model)
  assert_true(harness.has_text("Write in Markdown. Formatting appears as you type."))
  let two = update(model, @app.FloatNewNote)
  let second = float_test_active_note(two)
  assert_true(first.id != second.id)
  let two = update(two, @app.FloatNoteContentDraft("second body"))
  let first_tab_id = match float_active_tab(model.float) {
    Some(tab) => tab.id
    None => fail("expected the first note tab")
  }
  let back = update(two, FloatSelectTab(first_tab_id))
  let first_again = float_test_active_note(back)
  assert_eq(first_again.content, "")
  assert_eq(first_again.session.source(), "")
  match float_note_by_id(back.float, second.id) {
    Some(note) => assert_eq(note.content, "second body")
    None => fail("expected the second note to retain its content")
  }
}

///|
test "note toolbar formats the selection and toggles source without data loss" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let note = float_test_active_note(model)
  let model = update(model, @app.FloatNoteContentDraft("# 标题\n\n正文"))
  let model = update(
    model,
    @app.FloatNoteSelection(
      note.id,
      8,
      Some(@core.TextRange::new(start=6, end=8)),
    ),
  )
  let (harness, cell) = float_test_captured_harness(model)
  for label in ["H1", "H2", "H3", "B", "I", "•", "1.", "Q", "`", "{}", "Link", "Markdown"] {
    assert_true(harness.has_text(label))
  }
  harness.tap_text("B")
  let bold = float_test_active_note(cell.val)
  assert_eq(bold.content, "# 标题\n\n**正文**")
  harness.tap_text("Markdown")
  let source = float_test_active_note(cell.val)
  assert_true(source.source_mode)
  assert_eq(source.content, bold.content)
  assert_eq(source.revision, bold.revision)
  harness.tap_text("Markdown")
  let formatted = float_test_active_note(cell.val)
  assert_false(formatted.source_mode)
  assert_eq(formatted.content, bold.content)
  assert_eq(formatted.revision, bold.revision)
}

///|
test "IME composition does not write to the note until commit" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let (harness, cell) = float_test_captured_harness(model)
  let runtime = harness.runtime()
  assert_true(runtime.focus_key("float-note-editor:n1"))
  let before = float_test_active_note(cell.val)
  harness.dispatch(TextInput(CompositionStart))
  harness.dispatch(
    TextInput(
      CompositionUpdate(
        @core.CompositionUpdate::new(
          text="ni",
          cursor=Some(@core.TextRange::new(start=0, end=2)),
        ),
      ),
    ),
  )
  let composing = float_test_active_note(cell.val)
  assert_eq(composing.content, before.content)
  assert_eq(composing.revision, before.revision)
  harness.dispatch(TextInput(CompositionEnd("你")))
  let committed = float_test_active_note(cell.val)
  assert_eq(committed.content, "你")
  assert_eq(committed.session.source(), "你")
  assert_eq(committed.selection.caret, 1)
  harness.dispatch(TextInput(InsertText("好")))
  let typed = float_test_active_note(cell.val)
  assert_eq(typed.content, "你好")
  assert_eq(typed.selection.caret, 2)
}

///|
test "note editor undo and redo restore typed Markdown source" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let (harness, cell) = float_test_captured_harness(model)
  let runtime = harness.runtime()
  assert_true(runtime.focus_key("float-note-editor:n1"))
  harness.dispatch(TextInput(InsertText("abc")))
  assert_eq(float_test_active_note(cell.val).content, "abc")
  ignore(runtime.dispatch_focused_text_command(@core.CommandIntent::Undo))
  assert_eq(float_test_active_note(cell.val).content, "")
  ignore(runtime.dispatch_focused_text_command(@core.CommandIntent::Redo))
  assert_eq(float_test_active_note(cell.val).content, "abc")
}

///|
test "typing Markdown block markers keeps canonical source" {
  let cases : Array[Array[String]] = [
    ["#", " ", "标题"],
    ["##", " ", "小节"],
    ["-", " ", "项目"],
    ["1", ".", " ", "第一项"],
    [">", " ", "引用"],
  ]
  for keys in cases {
    let model = update(float_test_base_model(), ToggleFloatWorkspace)
    let (harness, cell) = float_test_captured_harness(model)
    let runtime = harness.runtime()
    assert_true(runtime.focus_key("float-note-editor:n1"))
    for key in keys {
      harness.dispatch(TextInput(InsertText(key)))
    }
    let note = float_test_active_note(cell.val)
    assert_eq(note.content, note.session.source())
    if keys[0] == "#" || keys[0] == "##" {
      assert_true(note.content.has_prefix(keys[0] + " "))
    } else if keys[0] == "-" {
      assert_true(note.content.has_prefix("- "))
    } else if keys[0] == "1" {
      assert_true(note.content.has_prefix("1. "))
    } else {
      assert_true(note.content.has_prefix("> "))
    }
  }
}

///|
test "formatting shortcuts are bound to the active note only" {
  let model = update(float_test_base_model(), ToggleFloatWorkspace)
  let note = float_test_active_note(model)
  let commands = program().runtime_commands(model)
  let mut bold_bindings = 0
  let mut italic_bindings = 0
  for program_command in commands {
    let action = program_command.command()
    match action.shortcut {
      Some(shortcut) =>
        if shortcut.modifiers.meta || shortcut.modifiers.control {
          match program_command.message() {
            @app.FloatNoteCommand(note_id, command) => {
              assert_eq(note_id, note.id)
              if command == @richtext.MarkdownEditorCommand::Bold {
                assert_eq(shortcut.key, "b")
                bold_bindings = bold_bindings + 1
              } else if command == @richtext.MarkdownEditorCommand::Italic {
                assert_eq(shortcut.key, "i")
                italic_bindings = italic_bindings + 1
              }
            }
            _ => ()
          }
        }
      None => ()
    }
  }
  assert_eq(bold_bindings, 2)
  assert_eq(italic_bindings, 2)
  let agent = update(model, @app.FloatNewAgent)
  for program_command in program().runtime_commands(agent) {
    match program_command.message() {
      @app.FloatNoteCommand(_, _) =>
        fail("Agent tab must not bind note formatting")
      _ => ()
    }
  }
}

///|
test "Cmd or Ctrl+B and Cmd or Ctrl+I format the selected note text" {
  for use_meta in [true, false] {
    for key_command in ["b", "i"] {
      let model = update(float_test_base_model(), ToggleFloatWorkspace)
      let note = float_test_active_note(model)
      let model = update(model, @app.FloatNoteContentDraft("text"))
      let model = update(
        model,
        @app.FloatNoteSelection(
          note.id,
          4,
          Some(@core.TextRange::new(start=0, end=4)),
        ),
      )
      let (harness, cell) = float_test_captured_program_harness(model)
      let runtime = harness.runtime()
      assert_true(runtime.focus_key("float-note-editor:n1"))
      harness.dispatch(
        Keyboard(
          @core.KeyboardEvent::new(
            key=key_command,
            code=if key_command == "b" { "KeyB" } else { "KeyI" },
            modifiers=@core.KeyModifiers::new(meta=use_meta, control=!use_meta),
          ),
        ),
      )
      let formatted = float_test_active_note(cell.val)
      if key_command == "b" {
        assert_eq(formatted.content, "**text**")
      } else {
        assert_eq(formatted.content, "*text*")
      }
    }
  }
}
