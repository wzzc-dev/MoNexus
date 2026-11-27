///|
fn terminal_test_record() -> @contracts.WorkspaceRecord {
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
/// Opening a focused terminal with a live session: the state the polling and
/// input tests start from.
fn terminal_test_running_model() -> Model {
  let model = update(Model::new(), SelectPage(Manage))
  let model = update(model, ProjectOpened(terminal_test_record()))
  let model = update(model, ProjectTerminalFocus)
  update(model, ProjectTerminalOpened("sess_test", "$ ", 2L, false))
}

///|
test "terminal.open applies initial text, cursor and eof" {
  assert_eq(terminal_transcript_text(""), "$ ")
  assert_eq(terminal_transcript_text("$ ready\n"), "$ ready\n")
  let model = update(Model::new(), SelectPage(Manage))
  let model = update(model, ProjectOpened(terminal_test_record()))
  let (opening, commands) = update_full(model, ProjectTerminalFocus)
  assert_eq(opening.project.terminal_state, TerminalOpening)
  assert_eq(commands.length(), 1)
  match commands[0] {
    ProjectOpenTerminal(workspace_id, rows, cols) => {
      assert_eq(workspace_id, "wsp_test")
      assert_eq((rows, cols), terminal_focused_pty_size())
    }
    _ => fail("expected ProjectOpenTerminal")
  }
  let opened = update(
    opening,
    ProjectTerminalOpened("sess_live", "$ echo hello\n$ ", 15L, false),
  )
  assert_eq(opened.project.terminal_id, "sess_live")
  assert_eq(opened.project.terminal_text, "$ echo hello\n$ ")
  assert_eq(opened.project.terminal_cursor, 15L)
  assert_eq(opened.project.terminal_eof, false)
  assert_eq(opened.project.terminal_state, TerminalRunning)
  assert_true(terminal_should_poll(opened))
  let eof = update(
    opening,
    ProjectTerminalOpened("sess_eof", "$ done\n", 7L, true),
  )
  assert_eq(eof.project.terminal_text, "$ done\n")
  assert_eq(eof.project.terminal_cursor, 7L)
  assert_eq(eof.project.terminal_eof, true)
  assert_eq(eof.project.terminal_state, TerminalEnded)
  assert_false(terminal_should_poll(eof))
}

///|
test "polling appends only fresh text and never overlaps reads" {
  let model = terminal_test_running_model()
  let (reading, commands) = update_full(model, ProjectTerminalPoll)
  assert_true(reading.project.terminal_read_in_flight)
  assert_eq(commands.length(), 1)
  match commands[0] {
    ProjectTerminalRead(session_id, cursor) => {
      assert_eq(session_id, "sess_test")
      assert_eq(cursor, 2L)
    }
    _ => fail("expected ProjectTerminalRead")
  }
  let (overlapping, overlap_commands) = update_full(
    reading,
    ProjectTerminalPoll,
  )
  assert_true(overlapping.project.terminal_read_in_flight)
  assert_eq(overlap_commands.length(), 0)
  let applied = update(
    overlapping,
    ProjectTerminalOutput("sess_test", 7L, "ok\n", false),
  )
  assert_eq(applied.project.terminal_text, "$ ok\n")
  assert_eq(applied.project.terminal_cursor, 7L)
  assert_false(applied.project.terminal_read_in_flight)
  let duplicate = update(
    applied,
    ProjectTerminalOutput("sess_test", 7L, "ok\n", false),
  )
  assert_eq(duplicate.project.terminal_text, "$ ok\n")
  assert_eq(duplicate.project.terminal_cursor, 7L)
  let stale = update(
    applied,
    ProjectTerminalOutput("sess_test", 5L, "old", false),
  )
  assert_eq(stale.project.terminal_text, "$ ok\n")
  assert_eq(stale.project.terminal_cursor, 7L)
  let wrong_session = update(
    applied,
    ProjectTerminalOutput("sess_other", 99L, "other", false),
  )
  assert_eq(wrong_session.project.terminal_text, "$ ok\n")
  assert_eq(wrong_session.project.terminal_cursor, 7L)
  let (_, next_read) = update_full(applied, ProjectTerminalPoll)
  match next_read[0] {
    ProjectTerminalRead(_, cursor) => assert_eq(cursor, 7L)
    _ => fail("expected ProjectTerminalRead")
  }
}

///|
test "enter submits a command, clears input and records history" {
  let model = update(
    terminal_test_running_model(),
    ProjectTerminalInput("echo hello"),
  )
  let (sent, commands) = update_full(model, ProjectTerminalSend)
  assert_eq(sent.project.terminal_input, "")
  assert_eq(sent.project.terminal_history.length(), 1)
  assert_eq(sent.project.terminal_history[0], "echo hello")
  assert_eq(commands.length(), 1)
  match commands[0] {
    ProjectTerminalWrite(session_id, data) => {
      assert_eq(session_id, "sess_test")
      assert_eq(data, "echo hello\n")
    }
    _ => fail("expected ProjectTerminalWrite")
  }
  let duplicate = update(sent, ProjectTerminalInput("echo hello"))
  let (sent_again, _) = update_full(duplicate, ProjectTerminalSend)
  assert_eq(sent_again.project.terminal_history.length(), 1)
}

///|
test "recent history chips fill the command field" {
  let model = update(
    terminal_test_running_model(),
    ProjectTerminalHistory("ls -la"),
  )
  assert_eq(model.project.terminal_input, "ls -la")
}

///|
test "stop sends the raw Ctrl+C byte instead of a command line" {
  let model = terminal_test_running_model()
  let (_, commands) = update_full(model, ProjectTerminalStop)
  assert_eq(commands.length(), 1)
  match commands[0] {
    ProjectTerminalWrite(session_id, data) => {
      assert_eq(session_id, "sess_test")
      assert_eq(data, "\u{3}")
    }
    _ => fail("expected ProjectTerminalWrite")
  }
  let closed = update(model, ProjectTerminalClose)
  let (_, stopped) = update_full(closed, ProjectTerminalStop)
  assert_eq(stopped.length(), 0)
}

///|
test "clear keeps the session and close resets it for reopening" {
  let model = terminal_test_running_model()
  let cleared = update(model, ProjectTerminalClear)
  assert_eq(cleared.project.terminal_id, "sess_test")
  assert_eq(cleared.project.terminal_cursor, 2L)
  assert_eq(cleared.project.terminal_state, TerminalRunning)
  assert_eq(cleared.project.terminal_text, "")
  let (closed, commands) = update_full(cleared, ProjectTerminalClose)
  assert_eq(closed.project.terminal_id, "")
  assert_eq(closed.project.terminal_text, "")
  assert_eq(closed.project.terminal_cursor, 0L)
  assert_eq(closed.project.terminal_state, TerminalClosed)
  assert_true(closed.project.terminal_focus)
  assert_eq(commands.length(), 1)
  match commands[0] {
    ProjectCloseTerminal(session_id) => assert_eq(session_id, "sess_test")
    _ => fail("expected ProjectCloseTerminal")
  }
  let (reopening, reopen_commands) = update_full(closed, ProjectTerminalFocus)
  assert_eq(reopening.project.terminal_state, TerminalOpening)
  assert_eq(reopen_commands.length(), 1)
  match reopen_commands[0] {
    ProjectOpenTerminal(workspace_id, rows, cols) => {
      assert_eq(workspace_id, "wsp_test")
      assert_eq((rows, cols), terminal_focused_pty_size())
    }
    _ => fail("expected ProjectOpenTerminal")
  }
  let fresh = update(
    reopening,
    ProjectTerminalOpened("sess_new", "$ ", 2L, false),
  )
  assert_eq(fresh.project.terminal_id, "sess_new")
  assert_eq(fresh.project.terminal_state, TerminalRunning)
}

///|
test "reconnect closes the lost session before opening a new one" {
  let ended = update(
    terminal_test_running_model(),
    ProjectTerminalOutput("sess_test", 5L, "bye\n", true),
  )
  assert_eq(ended.project.terminal_state, TerminalEnded)
  let (reconnecting, commands) = update_full(ended, ProjectTerminalReconnect)
  assert_eq(commands.length(), 2)
  match commands[0] {
    ProjectCloseTerminal(session_id) => assert_eq(session_id, "sess_test")
    _ => fail("expected ProjectCloseTerminal")
  }
  match commands[1] {
    ProjectOpenTerminal(workspace_id, rows, cols) => {
      assert_eq(workspace_id, "wsp_test")
      assert_eq((rows, cols), terminal_focused_pty_size())
    }
    _ => fail("expected ProjectOpenTerminal")
  }
  assert_eq(reconnecting.project.terminal_state, TerminalOpening)
  assert_eq(reconnecting.project.terminal_text, "")
  assert_eq(reconnecting.project.terminal_id, "")
}

///|
test "a failed read stops polling and exposes reconnect" {
  let model = terminal_test_running_model()
  let (reading, _) = update_full(model, ProjectTerminalPoll)
  assert_true(reading.project.terminal_read_in_flight)
  let failed = update(
    reading,
    ProjectTerminalFailed("sess_test", "terminal.read: connection lost"),
  )
  assert_eq(failed.project.terminal_state, TerminalFailed)
  assert_eq(failed.project.terminal_error, "terminal.read: connection lost")
  assert_false(failed.project.terminal_read_in_flight)
  assert_false(terminal_should_poll(failed))
  let (reconnecting, commands) = update_full(failed, ProjectTerminalReconnect)
  assert_eq(reconnecting.project.terminal_state, TerminalOpening)
  assert_eq(reconnecting.project.terminal_error, "")
  assert_eq(commands.length(), 2)
  match commands[0] {
    ProjectCloseTerminal(session_id) => assert_eq(session_id, "sess_test")
    _ => fail("expected ProjectCloseTerminal")
  }
  match commands[1] {
    ProjectOpenTerminal(workspace_id, rows, cols) => {
      assert_eq(workspace_id, "wsp_test")
      assert_eq((rows, cols), terminal_focused_pty_size())
    }
    _ => fail("expected ProjectOpenTerminal")
  }
}

///|
test "EOF ends the session and stops polling" {
  let model = update(
    terminal_test_running_model(),
    ProjectTerminalOutput("sess_test", 6L, "bye\n", true),
  )
  assert_eq(model.project.terminal_state, TerminalEnded)
  assert_eq(model.project.terminal_eof, true)
  assert_eq(model.project.terminal_text, "$ bye\n")
  assert_false(terminal_should_poll(model))
  let (_, commands) = update_full(model, ProjectTerminalPoll)
  assert_eq(commands.length(), 0)
  assert_eq(terminal_poll_subscription(model).descriptors().length(), 0)
}

///|
test "the live session survives page navigation" {
  let model = terminal_test_running_model()
  assert_true(terminal_should_poll(model))
  assert_eq(terminal_poll_subscription(model).descriptors().length(), 1)
  let away = update(model, SelectPage(Workroom))
  assert_eq(away.page.label(), "Workroom")
  assert_eq(away.project.terminal_id, "sess_test")
  assert_eq(away.project.terminal_text, "$ ")
  assert_eq(away.project.terminal_cursor, 2L)
  assert_false(terminal_should_poll(away))
  assert_eq(terminal_poll_subscription(away).descriptors().length(), 0)
  let back = update(away, SelectPage(Manage))
  assert_eq(back.page.label(), "Manage")
  assert_eq(back.project.terminal_id, "sess_test")
  assert_eq(back.project.terminal_text, "$ ")
  assert_eq(back.project.terminal_cursor, 2L)
  assert_true(terminal_should_poll(back))
  assert_eq(
    terminal_poll_subscription(back).descriptors()[0].key(),
    "project-terminal-poll",
  )
  let reopened = update(back, ProjectOpened(terminal_test_record()))
  assert_eq(reopened.project.terminal_id, "sess_test")
  assert_eq(reopened.project.terminal_text, "$ ")
}

///|
test "opening the focused terminal requests the computed viewport size" {
  let model = update(Model::new(), SelectPage(Manage))
  let model = update(model, ProjectOpened(terminal_test_record()))
  let (opening, commands) = update_full(model, ProjectTerminalFocus)
  let expected = terminal_focused_pty_size()
  assert_true(expected.0 > 0)
  assert_true(expected.1 > 0)
  assert_eq(
    (opening.project.terminal_target_rows, opening.project.terminal_target_cols),
    expected,
  )
  assert_eq(
    (opening.project.terminal_pty_rows, opening.project.terminal_pty_cols),
    expected,
  )
  match commands[0] {
    ProjectOpenTerminal(_, rows, cols) => assert_eq((rows, cols), expected)
    _ => fail("expected ProjectOpenTerminal")
  }
}

///|
test "viewport resize is emitted once per real size change" {
  let model = terminal_test_running_model()
  let base = terminal_focused_pty_size()
  let (unchanged, no_commands) = update_full(
    model,
    ProjectTerminalViewport(base.0, base.1),
  )
  assert_eq(no_commands.length(), 0)
  assert_eq(
    (
      unchanged.project.terminal_target_rows,
      unchanged.project.terminal_target_cols,
    ),
    base,
  )
  let wanted = (base.0 + 1, base.1 + 2)
  let (resized, commands) = update_full(
    model,
    ProjectTerminalViewport(wanted.0, wanted.1),
  )
  assert_eq(commands.length(), 1)
  match commands[0] {
    ProjectTerminalResize(session_id, rows, cols) => {
      assert_eq(session_id, "sess_test")
      assert_eq((rows, cols), wanted)
    }
    _ => fail("expected ProjectTerminalResize")
  }
  assert_eq(
    (resized.project.terminal_pty_rows, resized.project.terminal_pty_cols),
    wanted,
  )
  let (_, duplicate) = update_full(
    resized,
    ProjectTerminalViewport(wanted.0, wanted.1),
  )
  assert_eq(duplicate.length(), 0)
}

///|
test "a viewport change during terminal.open reconciles after open" {
  let model = update(Model::new(), SelectPage(Manage))
  let model = update(model, ProjectOpened(terminal_test_record()))
  let (opening, open_commands) = update_full(model, ProjectTerminalFocus)
  let open_size = match open_commands[0] {
    ProjectOpenTerminal(_, rows, cols) => (rows, cols)
    _ => fail("expected ProjectOpenTerminal")
  }
  let wanted = (open_size.0 + 2, open_size.1 + 3)
  let (opening, during_open) = update_full(
    opening,
    ProjectTerminalViewport(wanted.0, wanted.1),
  )
  assert_eq(during_open.length(), 0)
  let (opened, after_open) = update_full(
    opening,
    ProjectTerminalOpened("sess_resized", "$ ", 2L, false),
  )
  assert_eq(after_open.length(), 1)
  match after_open[0] {
    ProjectTerminalResize(session_id, rows, cols) => {
      assert_eq(session_id, "sess_resized")
      assert_eq((rows, cols), wanted)
    }
    _ => fail("expected ProjectTerminalResize")
  }
  assert_eq(
    (opened.project.terminal_pty_rows, opened.project.terminal_pty_cols),
    wanted,
  )
  let (_, duplicate) = update_full(
    opened,
    ProjectTerminalViewport(wanted.0, wanted.1),
  )
  assert_eq(duplicate.length(), 0)
}

///|
test "float resize updates the target without RPCs and syncs once on end" {
  let base = update(terminal_test_running_model(), ToggleFloatWorkspace)
  let model = update(base, FloatNewTerminal)
  let (started, started_commands) = update_full(
    model,
    FloatResizeDrag(@core.DragGesturePhase::Started, 0.0, 0.0),
  )
  assert_eq(started_commands.length(), 0)
  let (dragging, changed_commands) = update_full(
    started,
    FloatResizeDrag(@core.DragGesturePhase::Changed, 60.0, 40.0),
  )
  assert_eq(changed_commands.length(), 0)
  let wanted = terminal_float_pty_size(dragging)
  assert_eq(
    (
      dragging.project.terminal_target_rows,
      dragging.project.terminal_target_cols,
    ),
    wanted,
  )
  let (ended, end_commands) = update_full(
    dragging,
    FloatResizeDrag(@core.DragGesturePhase::Ended, 60.0, 40.0),
  )
  assert_eq(end_commands.length(), 1)
  match end_commands[0] {
    ProjectTerminalResize(session_id, rows, cols) => {
      assert_eq(session_id, "sess_test")
      assert_eq((rows, cols), wanted)
    }
    _ => fail("expected ProjectTerminalResize")
  }
  assert_eq(
    (ended.project.terminal_pty_rows, ended.project.terminal_pty_cols),
    wanted,
  )
  let (_, duplicate) = update_full(
    ended,
    FloatResizeDrag(@core.DragGesturePhase::Ended, 60.0, 40.0),
  )
  assert_eq(duplicate.length(), 0)
}
