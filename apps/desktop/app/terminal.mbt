///|
/// Visible lifecycle of the selected project's PTY session. The host owns the
/// process; this enum only describes what the focused terminal surface can do
/// right now.
#derive(Eq, Debug)
pub(all) enum TerminalState {
  TerminalClosed
  TerminalOpening
  TerminalRunning
  TerminalEnded
  TerminalFailed
}

///|
fn terminal_state_label(state : TerminalState, lang : Lang) -> String {
  match state {
    TerminalClosed => tr(lang, "closed", "已关闭")
    TerminalOpening => tr(lang, "opening", "正在打开")
    TerminalRunning => tr(lang, "running", "运行中")
    TerminalEnded => tr(lang, "ended", "已结束")
    TerminalFailed => tr(lang, "error", "错误")
  }
}

///|
/// The poll subscription lives only while the focused terminal is visible and
/// the session can still produce output. Page navigation and the back action
/// therefore stop host reads; the protocol cursor lets the next visit resume
/// from the last byte instead of replaying the transcript.
pub fn terminal_should_poll(model : Model) -> Bool {
  let focused_manage = model.page == Manage &&
    model.manage_tab == ManageProjects &&
    model.project.terminal_focus
  let overlay_terminal = float_terminal_visible(model) &&
    model.project.terminal_focus
  (focused_manage || overlay_terminal) &&
  model.project.terminal_focus &&
  model.project.terminal_id != "" &&
  model.project.terminal_state == TerminalRunning &&
  !model.project.terminal_eof
}

///|
/// Recent-command ring used by the clickable history chips. Consecutive
/// duplicates collapse, and the list is capped so a long session cannot grow
/// the model without bound.
fn terminal_history_push(
  history : Array[String],
  command : String,
) -> Array[String] {
  if command == "" {
    return history.copy()
  }
  if !history.is_empty() && history[history.length() - 1] == command {
    return history.copy()
  }
  let next : Array[String] = []
  let keep = if history.length() >= 50 { 49 } else { history.length() }
  let mut index = history.length() - keep
  while index < history.length() {
    next.push(history[index])
    index = index + 1
  }
  next.push(command)
  next
}

///|
/// Terminal output is delta text keyed by the host cursor. A stale session or
/// a cursor that did not advance is ignored, so polling cannot duplicate a
/// chunk that an overlapping read already applied.
fn terminal_text_after_read(
  current : String,
  cursor : Int64,
  next_cursor : Int64,
  text : String,
) -> String {
  if next_cursor > cursor {
    current + text
  } else {
    current
  }
}

///|
/// The transcript always shows a prompt, even before the host returns its
/// first chunk. The host owns the real shell prompt inside `text`; this is a
/// local affordance so the focused surface never looks blank while opening.
fn terminal_transcript_text(text : String) -> String {
  if text == "" {
    "$ "
  } else {
    text
  }
}

///|
/// Commands are submitted with Enter, so the host receives one newline. The
/// interrupt byte is sent by `ProjectTerminalStop` as raw input and never goes
/// through this helper.
fn terminal_command_payload(command : String) -> String {
  if command.has_suffix("\n") {
    command
  } else {
    command + "\n"
  }
}

///|
/// Conservative wrapped-line estimate for the selectable transcript view.
/// MoUI's own text layout does the real wrapping; this only sizes the child so
/// the outer scroll view can own a stable viewport and auto-follow the tail.
fn terminal_visual_line_count(text : String, columns : Int32) -> Int32 {
  if columns <= 0 {
    return 1
  }
  let mut lines : Int32 = 1
  let mut units : Int32 = 0
  for ch in text {
    if ch == '\n' {
      lines = lines + 1
      units = 0
    } else {
      let width : Int32 = if ch.is_ascii() { 1 } else { 2 }
      if units + width > columns {
        lines = lines + 1
        units = width
      } else {
        units = units + width
      }
    }
  }
  lines
}

///|
fn terminal_history_label(command : String) -> String {
  let one_line = command.replace(old="\n", new=" ")
  if one_line.length() > 28 {
    one_line[:28].to_owned() + "…"
  } else {
    one_line
  }
}

///|
/// The timer worker dispatches only while a subscription is installed; the
/// subscription itself is model-driven, so closing the session, reaching EOF,
/// leaving Projects or returning to the project browse view cancels it.
let terminal_poll_interval_ms : Int32 = 250

///|
let terminal_poll_dispatch : Ref[((Msg) -> Unit)?] = Ref(None)

///|
let terminal_poll_generation : Ref[Int32] = Ref(0)

///|
pub async fn terminal_poll_loop() -> Unit {
  for ;; {
    @async.sleep(terminal_poll_interval_ms)
    match terminal_poll_dispatch.val {
      Some(dispatch) => dispatch(ProjectTerminalPoll)
      None => ()
    }
  }
}

///|
fn terminal_poll_subscription(model : Model) -> @moui.Subscription[Msg] {
  if !terminal_should_poll(model) {
    return @moui.Subscription::none()
  }
  @moui.Subscription::timer(
    key="project-terminal-poll",
    label="Poll project terminal output",
    start=dispatch => {
      let generation = terminal_poll_generation.val + 1
      terminal_poll_generation.val = generation
      terminal_poll_dispatch.val = Some(dispatch)
      Some(fn() {
        // A cancellation for an older mount must not clear the dispatch owned
        // by the next terminal mount.
        if terminal_poll_generation.val == generation {
          terminal_poll_dispatch.val = None
        }
      })
    },
  )
}
