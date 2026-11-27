///|
/// Focused terminal surface. It replaces the Projects body while active, so
/// the transcript owns a stable viewport instead of sharing the long project
/// card scroll. The host protocol stays unchanged: `terminal.open` still uses
/// a fixed 24x80 PTY and `terminal.read` still advances by byte cursor.
let terminal_transcript_width : Double = 960.0

///|
let terminal_transcript_height : Double = 360.0

///|
let terminal_line_height : Double = 18.0

///|
fn terminal_focus_active(model : Model) -> Bool {
  model.page == Projects &&
  model.project.terminal_focus &&
  model.project.workspace is Some(_)
}

///|
fn terminal_state_tone(state : TerminalState) -> @core.Color {
  match state {
    TerminalClosed => ui_dim()
    TerminalOpening => ui_warning()
    TerminalRunning => ui_success()
    TerminalEnded => ui_warning()
    TerminalFailed => ui_danger()
  }
}

///|
fn terminal_session_label(session_id : String) -> String {
  if session_id.length() > 12 {
    session_id[:8].to_owned() + "…"
  } else {
    session_id
  }
}

///|
/// Selectable transcript theme: the code well background with a monospace
/// body. MoUI's text area carries selection, wheel scrolling and clipboard
/// support; on_input is discarded by the update function so the view stays
/// read-only without private APIs.
fn terminal_transcript_theme() -> @core.Theme {
  let base = field_theme()
  let palette = base.palette
  base
  .with_palette({
    ..palette,
    surface: ui_code_bg(),
    surface_variant: ui_code_bg(),
  })
  .with_typography({ ..base.typography, body: mono_font(11.5, 400), })
}

///|
/// Transcript viewport. New output bumps `terminal_scroll_epoch`, which asks
/// the scroll view to follow the tail; a fixed request id lets the user wheel
/// back through history without every repaint yanking them to the bottom.
fn terminal_transcript_view(model : Model) -> @moui.View[Msg] {
  let text = terminal_transcript_text(model.project.terminal_text)
  let lines = match terminal_visual_line_count(text, 104) {
    count if count < 20 => 20
    count => count
  }
  let content_height = lines.to_double() * terminal_line_height + 24.0
  let offset_y = (content_height - terminal_transcript_height).max(0.0)
  let content = @views.text_area(
    text,
    on_input=fn(_value) { ProjectTerminalTranscriptEdited("") },
    variant=@style.TextFieldVariant::Filled,
    theme=terminal_transcript_theme(),
    width=terminal_transcript_width,
    lines~,
    line_height=terminal_line_height,
  )
  @views.scroll_view(
    content,
    width=terminal_transcript_width,
    height=terminal_transcript_height,
    request=@core.ScrollRequest::new(
      id=model.project.terminal_scroll_epoch,
      offset=@core.Point::new(x=0.0, y=offset_y),
    ),
    shows_indicator=true,
  )
}

///|
fn terminal_header(
  model : Model,
  record : @contracts.WorkspaceRecord,
) -> @moui.View[Msg] {
  let project = model.project
  row(
    [
      ui_ghost_small(
        tr(model.lang, "Back to projects", "返回项目"),
        ProjectTerminalBack,
      ),
      column(
        [
          ui_section(tr(model.lang, "Terminal", "终端")),
          ui_row_title(record.name),
          ui_mono(record.root, 10.5),
        ],
        spacing=2.0,
        align=@style.CrossAlign::Start,
      ),
      spacer(weight=1.0),
      column(
        [
          ui_state_pill(
            terminal_state_label(project.terminal_state, model.lang),
            terminal_state_tone(project.terminal_state),
          ),
          ui_meta(
            tr(model.lang, "session ", "会话 ") +
            (if project.terminal_id == "" {
              tr(model.lang, "(none)", "（无）")
            } else {
              terminal_session_label(project.terminal_id)
            }),
          ),
        ],
        spacing=4.0,
        align=@style.CrossAlign::End,
      ),
    ],
    spacing=12.0,
    align=@style.CrossAlign::Center,
  ).frame(width=terminal_transcript_width)
}

///|
fn terminal_input_row(model : Model) -> @moui.View[Msg] {
  let running = model.project.terminal_state == TerminalRunning
  row(
    [
      text("$", align=@core.TextAlign::TextStart)
      .font(mono_font(13.0, 600))
      .foreground(if running { ui_accent() } else { ui_dim() }),
      @views.text_field(
        model.project.terminal_input,
        on_input=fn(value) { ProjectTerminalInput(value) },
        on_submit=Some(ProjectTerminalSend),
        placeholder=tr(
          model.lang,
          "type a command, Enter sends",
          "输入命令，Enter 发送",
        ),
        style=ui_field_style(),
        width=620.0,
        height=34.0,
      ),
      ui_primary(tr(model.lang, "Send", "发送"), ProjectTerminalSend),
      ui_danger_ghost(tr(model.lang, "Stop", "停止"), ProjectTerminalStop),
      ui_ghost_small(tr(model.lang, "Clear", "清空"), ProjectTerminalClear),
      ui_ghost_small(tr(model.lang, "Close", "关闭"), ProjectTerminalClose),
    ],
    spacing=8.0,
    align=@style.CrossAlign::Center,
  ).frame(width=terminal_transcript_width)
}

///|
fn terminal_hint(model : Model) -> @moui.View[Msg] {
  ui_meta(
    tr(
      model.lang,
      "Enter sends · Ctrl+Shift+C or Stop interrupts · fixed PTY 24x80",
      "Enter 发送 · Ctrl+Shift+C 或 Stop 中断 · 固定 PTY 24x80",
    ),
  )
}

///|
fn terminal_history_row(model : Model) -> @moui.View[Msg]? {
  let history = model.project.terminal_history
  if history.is_empty() {
    return None
  }
  let children : Array[@moui.View[Msg]] = [
    ui_meta(tr(model.lang, "Recent", "最近")),
  ]
  let start = if history.length() > 3 { history.length() - 3 } else { 0 }
  let mut index = start
  while index < history.length() {
    let command = history[index]
    children.push(
      ui_ghost_small(
        terminal_history_label(command),
        ProjectTerminalHistory(command),
      ),
    )
    index = index + 1
  }
  Some(
    row(children, spacing=8.0, align=@style.CrossAlign::Center).frame(
      width=terminal_transcript_width,
    ),
  )
}

///|
fn terminal_reconnect_row(model : Model) -> @moui.View[Msg]? {
  let state = model.project.terminal_state
  match state {
    TerminalEnded | TerminalFailed | TerminalClosed =>
      Some(
        row(
          [
            ui_danger_ghost(
              tr(model.lang, "Reconnect", "重新连接"),
              ProjectTerminalReconnect,
            ),
            ui_meta(
              if state == TerminalEnded {
                tr(
                  model.lang,
                  "the shell exited (EOF)",
                  "shell 已退出（EOF）",
                )
              } else if state == TerminalClosed {
                tr(model.lang, "session closed", "会话已关闭")
              } else {
                tr(model.lang, "the session was lost", "会话已丢失")
              },
            ),
          ],
          spacing=10.0,
          align=@style.CrossAlign::Center,
        ),
      )
    TerminalOpening | TerminalRunning => None
  }
}

///|
fn terminal_error_view(model : Model) -> @moui.View[Msg]? {
  if model.project.terminal_error == "" {
    None
  } else {
    Some(
      text(
        model.project.terminal_error,
        width=terminal_transcript_width,
        align=@core.TextAlign::TextStart,
        wrap=true,
      )
      .font(ui_font(11.0, 400))
      .foreground(ui_danger()),
    )
  }
}

///|
/// The only body content in focused mode. Its outer size is 992x672, which
/// exactly fills the 1032x712 body viewport once the 20pt page padding is
/// applied by `main_island`; no page-level scroll view wraps it.
fn terminal_page(model : Model) -> @moui.View[Msg] {
  match model.project.workspace {
    Some(record) => {
      let children : Array[@moui.View[Msg]] = [
        terminal_header(model, record),
        ui_divider_soft(),
        terminal_transcript_view(model),
      ]
      match terminal_error_view(model) {
        Some(view) => children.push(view)
        None => ()
      }
      match terminal_reconnect_row(model) {
        Some(view) => children.push(view)
        None => ()
      }
      children.push(spacer(weight=1.0))
      children.push(terminal_input_row(model))
      children.push(terminal_hint(model))
      match terminal_history_row(model) {
        Some(view) => children.push(view)
        None => ()
      }
      @views.container(
        @views.padding(
          @views.column(children, spacing=8.0).frame(
            width=terminal_transcript_width,
            height=640.0,
          ),
          16.0,
        ),
        width=992.0,
        height=672.0,
        background=ui_surface(),
        corner_radius=10.0,
        border=Some(ui_edge(ui_border_soft())),
        padding=0.0,
      )
    }
    None =>
      ui_card(
        [
          ui_section(tr(model.lang, "Terminal", "终端")),
          ui_muted_wrapped(
            tr(
              model.lang,
              "Open a project first, then open its terminal.",
              "请先打开项目，然后打开其终端。",
            ),
            960.0,
          ),
        ],
        width=992.0,
      )
  }
}
