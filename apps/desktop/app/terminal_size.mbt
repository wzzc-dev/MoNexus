///|
/// PTY geometry follows the terminal's visible text box. The transcript uses
/// MoUI's filled text area, whose text frame is inset by 10pt horizontally and
/// 8pt vertically; row height is the widget's explicit 18pt slot grid.
let terminal_text_padding_x : Double = 20.0

///|
let terminal_text_padding_y : Double = 16.0

///|
fn terminal_cell_width() -> Double {
  let measured = @core.TextSystem::fallback().measure_text(
    @core.TextLayoutInput::new(text="M", font=mono_font(11.5, 400)),
  )
  measured.size.width.max(1.0)
}

///|
fn terminal_pty_size_from_box(width : Double, height : Double) -> (Int32, Int32) {
  let usable_width = (width - terminal_text_padding_x).max(1.0)
  let usable_height = (height - terminal_text_padding_y).max(1.0)
  let cols = (usable_width / terminal_cell_width()).to_int().clamp(
    min=@contracts.TERMINAL_MIN_SIZE,
    max=@contracts.TERMINAL_MAX_SIZE,
  )
  let rows = (usable_height / terminal_line_height).to_int().clamp(
    min=@contracts.TERMINAL_MIN_SIZE,
    max=@contracts.TERMINAL_MAX_SIZE,
  )
  (rows, cols)
}

///|
fn terminal_focused_pty_size() -> (Int32, Int32) {
  terminal_pty_size_from_box(
    terminal_transcript_width,
    terminal_transcript_height,
  )
}

///|
fn terminal_float_extra_height(model : Model) -> Double {
  let error_height = if model.project.terminal_error != "" {
    20.0
  } else {
    0.0
  }
  let reconnect_height = if model.project.terminal_state == TerminalEnded ||
    model.project.terminal_state == TerminalFailed {
    38.0
  } else {
    0.0
  }
  error_height + reconnect_height
}

///|
fn terminal_float_transcript_height(
  model : Model,
  inner_height : Double,
) -> Double {
  (inner_height - 115.0 - terminal_float_extra_height(model)).max(36.0)
}

///|
fn terminal_float_pty_size(model : Model) -> (Int32, Int32) {
  let width = model.float.width
  let height = model.float.height
  let inner_width = (width - float_body_padding * 2.0).max(0.0)
  let tabs_height = float_tabs_height(
    model.float,
    (width - 24.0).max(0.0),
  )
  let body_height = (height -
    (float_header_height + 1.0 + tabs_height)).max(0.0)
  let inner_height = (body_height - float_body_padding * 2.0).max(0.0)
  terminal_pty_size_from_box(
    inner_width,
    terminal_float_transcript_height(model, inner_height),
  )
}

///|
fn terminal_target_size(model : Model) -> (Int32, Int32) {
  if float_terminal_visible(model) {
    terminal_float_pty_size(model)
  } else {
    terminal_focused_pty_size()
  }
}

///|
/// The only signal that advances the PTY geometry. Keeping the last requested
/// size in the model makes repeated viewport reports idempotent: a frame that
/// recomputes the same rows/cols emits no RPC, while a real change emits one.
fn terminal_resize_command(
  model : Model,
  rows : Int32,
  cols : Int32,
) -> MachineCommand? {
  if model.project.terminal_id == "" ||
    model.project.terminal_state != TerminalRunning ||
    !@contracts.terminal_size_is_valid(rows, cols) ||
    (rows == model.project.terminal_pty_rows &&
      cols == model.project.terminal_pty_cols) {
    None
  } else {
    Some(
      ProjectTerminalResize(model.project.terminal_id, rows, cols),
    )
  }
}
