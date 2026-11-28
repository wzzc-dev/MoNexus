///|
/// Floating workspace presentation. The overlay is a sibling of the shell, not
/// a page: it never changes the route, reuses the workroom's Agent model and
/// the focused terminal's PTY view, and owns only local note presentation.

///|
let float_header_height : Double = 42.0

///|
let float_tab_row_height : Double = 32.0

///|
let float_tab_gap : Double = 4.0

///|
let float_tab_min_width : Double = 88.0

///|
let float_tab_max_width : Double = 150.0

///|
let float_body_padding : Double = 14.0

///|
let float_menu_width : Double = 214.0

///|
let float_menu_height : Double = 176.0

///|
fn float_compact_theme() -> @core.Theme {
  let base = app_theme()
  base
  .with_layout_scale({
    ..base.layout_scale,
    control_height: 24.0,
    control_padding_x: 6.0,
  })
  .with_typography({ ..base.typography, control: ui_font(11.0, 500), })
}

///|
fn float_tab_button_style(active : Bool) -> @views.ButtonStyle {
  let transparent = transparent_brush()
  let normal = @views.new_control_state_style(
    foreground=if active { ui_text_color() } else { ui_muted() },
    background=transparent,
    radius=4.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_hover()),
    radius=4.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_selected()),
    radius=4.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    radius=4.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
fn float_close_tab_button_style() -> @views.ButtonStyle {
  let transparent = transparent_brush()
  let normal = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    radius=4.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_danger(),
    background=@core.Brush::solid(ui_danger().multiply_alpha(0.08)),
    radius=4.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_danger(),
    background=@core.Brush::solid(ui_danger().multiply_alpha(0.14)),
    radius=4.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    radius=4.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
fn float_header_button_style() -> @views.ButtonStyle {
  let transparent = transparent_brush()
  let normal = @views.new_control_state_style(
    foreground=ui_muted(),
    background=transparent,
    radius=4.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_hover()),
    radius=4.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_selected()),
    radius=4.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    radius=4.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
fn float_plus_button_style(active : Bool) -> @views.ButtonStyle {
  let transparent = transparent_brush()
  let normal = @views.new_control_state_style(
    foreground=if active { ui_ink() } else { ui_muted() },
    background=if active {
      @core.Brush::solid(ui_selected())
    } else {
      transparent
    },
    radius=4.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_ink(),
    background=@core.Brush::solid(ui_hover()),
    radius=4.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_ink(),
    background=@core.Brush::solid(ui_selected()),
    radius=4.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    radius=4.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
fn float_menu_button_style() -> @views.ButtonStyle {
  let transparent = transparent_brush()
  let normal = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=transparent,
    radius=4.0,
  )
  let hovered = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_hover()),
    radius=4.0,
  )
  let pressed = @views.new_control_state_style(
    foreground=ui_text_color(),
    background=@core.Brush::solid(ui_selected()),
    radius=4.0,
  )
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    radius=4.0,
  )
  @views.ButtonStyle::new(normal~, hovered~, pressed~, disabled~)
}

///|
fn float_menu_disabled_style() -> @views.ButtonStyle {
  let transparent = transparent_brush()
  let disabled = @views.new_control_state_style(
    foreground=ui_dim(),
    background=transparent,
    radius=4.0,
  )
  @views.ButtonStyle::new(
    normal=disabled,
    hovered=disabled,
    pressed=disabled,
    disabled~,
  )
}

///|
fn float_key_activates(event : @core.KeyboardEvent) -> Bool {
  event.pressed &&
  (event.key == "Enter" || event.key == " " || event.key == "Spacebar")
}

///|
fn float_sidebar_item(model : Model) -> @moui.View[Msg] {
  let label = tr(model.lang, "Workspace", "浮岛工作区")
  let active = model.float.open
  let hovered = model.hover_row == "nav:float"
  let tone = if active {
    ui_ink()
  } else if hovered {
    ui_text_color()
  } else {
    ui_muted()
  }
  let background = if active {
    ui_selected()
  } else if hovered {
    ui_hover()
  } else {
    clear_color()
  }
  let children : Array[@moui.View[Msg]] = [
    container(
      @views.empty(),
      width=2.0,
      height=14.0,
      background=if active { ui_ink() } else { clear_color() },
      corner_radius=1.0,
      padding=0.0,
    ),
    lucide_icon("panel-right", size=16.0, color=tone),
    @views.text(label, align=@core.TextAlign::TextStart).font(
      ui_font(13.0, if active { 600 } else { 400 }),
    ).foreground(tone),
    @views.spacer(weight=1.0),
  ]
  if active {
    children.push(ui_dot(ui_accent()))
  }
  @views.container(
    @views.padding_xy(
      @views.row(children, spacing=10.0, align=@style.CrossAlign::Center).frame(
        width=168.0,
      ),
      horizontal=8.0,
    ),
    height=32.0,
    background~,
    corner_radius=4.0,
    padding=0.0,
  )
  .on_tap(ToggleFloatWorkspace)
  .on_hover(fn(over) { HoverRow("nav:float", over) })
  .focusable()
  .on_key(fn(event) {
    if float_key_activates(event) {
      ToggleFloatWorkspace
    } else {
      FloatNoop
    }
  })
  .semantics_role(@core.SemanticsRole::Button)
  .semantics_expanded(expanded=active)
  .accessibility_label(label)
  .cursor(@core.CursorStyle::Icon(@core.CursorIcon::CursorPointer))
}

///|
fn float_tab_label(workspace : FloatWorkspace, tab : FloatTab, lang : Lang) -> String {
  match tab.kind {
    FloatNote =>
      match float_note_by_id(workspace, tab.note_id) {
        Some(note) =>
          if note.title == "" {
            note.file_name
          } else {
            note.title
          }
        None => tr(lang, "Note", "笔记")
      }
    FloatAgent => tr(lang, "Agent", "Agent")
    FloatTerminal => tr(lang, "Terminal", "终端")
  }
}

///|
fn float_tab_icon(tab : FloatTab) -> @style.IconName {
  match tab.kind {
    FloatNote => @style.IconName::FileMarkdown
    FloatAgent => @style.IconName::Chat
    FloatTerminal => @style.IconName::CodeInline
  }
}

///|
fn float_tab_view(
  model : Model,
  tab : FloatTab,
  tab_width : Double,
) -> @moui.View[Msg] {
  let active = model.float.active_tab == tab.id
  let label = float_tab_label(model.float, tab, model.lang)
  let compact = float_compact_theme()
  let select_width = (tab_width - 30.0).max(44.0)
  let select = @views.button(
    label,
    on_click=FloatSelectTab(tab.id),
    style=float_tab_button_style(active),
    icon=Some(float_tab_icon(tab)),
    width=select_width,
    height=24.0,
  )
  .theme(compact)
  .semantics_role(@core.SemanticsRole::Tab)
  .semantics_selected(selected=active)
  .accessibility_label(
    tr(model.lang, "Open tab ", "打开标签 ") + label,
  )
  let close = @views.button(
    "×",
    on_click=FloatCloseTab(tab.id),
    style=float_close_tab_button_style(),
    width=20.0,
    height=22.0,
  )
  .theme(compact)
  .accessibility_label(
    tr(model.lang, "Close tab ", "关闭标签 ") + label,
  )
  let border = if active {
    Some(ui_edge(ui_border()))
  } else {
    None
  }
  @views.container(
    @views.row([select, close], spacing=0.0, align=@style.CrossAlign::Center),
    width=tab_width,
    height=30.0,
    background=if active { ui_selected() } else { clear_color() },
    corner_radius=4.0,
    border~,
    padding=0.0,
  )
  .on_tap(FloatSelectTab(tab.id))
  .cursor(@core.CursorStyle::Icon(@core.CursorIcon::CursorPointer))
}

///|
fn float_tabs_per_row(inner_width : Double) -> Int {
  let count = ((inner_width + float_tab_gap) /
    (float_tab_min_width + float_tab_gap)).to_int()
  if count < 1 {
    1
  } else {
    count
  }
}

///|
fn float_tab_rows(workspace : FloatWorkspace, inner_width : Double) -> Int {
  let count = workspace.tabs.length()
  if count == 0 {
    return 0
  }
  let per_row = float_tabs_per_row(inner_width)
  let rows = (count + per_row - 1) / per_row
  rows
}

///|
fn float_tabs_height(workspace : FloatWorkspace, inner_width : Double) -> Double {
  float_tab_rows(workspace, inner_width).to_double() * float_tab_row_height
}

///|
fn float_tabs_view(
  model : Model,
  inner_width : Double,
) -> @moui.View[Msg] {
  let per_row = float_tabs_per_row(inner_width)
  let rows : Array[@moui.View[Msg]] = []
  let count = model.float.tabs.length()
  let mut index = 0
  while index < count {
    let row_tabs : Array[@moui.View[Msg]] = []
    let end = (index + per_row).min(count)
    let slots = end - index
    let width = if slots > 1 {
      ((inner_width - float_tab_gap * (slots - 1).to_double()) /
        slots.to_double()).clamp(
        min=float_tab_min_width,
        max=float_tab_max_width,
      )
    } else {
      float_tab_max_width
    }
    let mut cursor = index
    while cursor < end {
      row_tabs.push(
        float_tab_view(model, model.float.tabs[cursor], width),
      )
      cursor = cursor + 1
    }
    rows.push(
      @views.row(row_tabs, spacing=float_tab_gap, align=@style.CrossAlign::Start).frame(
        width=inner_width,
        height=float_tab_row_height,
      ),
    )
    index = end
  }
  @views.column(rows, spacing=0.0).frame(
    width=inner_width,
    height=float_tabs_height(model.float, inner_width),
  )
}

///|
fn float_header(model : Model, width : Double) -> @moui.View[Msg] {
  let compact = float_compact_theme()
  let active_label = match float_active_tab(model.float) {
    Some(tab) => float_tab_label(model.float, tab, model.lang)
    None => tr(model.lang, "No open tab", "尚无标签")
  }
  let plus = @views.button(
    "+",
    on_click=FloatMenu(!model.float.menu_open),
    style=float_plus_button_style(model.float.menu_open),
    width=26.0,
    height=24.0,
  )
  .theme(compact)
  .accessibility_label(tr(model.lang, "New tab", "新建标签"))
  let close = @views.button(
    "",
    on_click=CloseFloatWorkspace,
    style=float_header_button_style(),
    icon=Some(@style.IconName::Close),
    width=24.0,
    height=24.0,
  )
  .theme(compact)
  .accessibility_label(
    tr(model.lang, "Close floating workspace", "关闭浮岛工作区"),
  )
  let content = @views.row([
    lucide_icon("panel-right", size=14.0, color=ui_muted()),
    @views.text(
      tr(model.lang, "Floating workspace", "浮岛工作区"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(13.0, 600)).foreground(ui_text_color()),
    @views.text(
      tr(model.lang, "beside Chat", "在对话旁"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(9.0, 400)).foreground(ui_dim()),
    @views.spacer(weight=1.0),
    @views.text(
      active_label,
      width=160.0,
      align=@core.TextAlign::TextEnd,
      wrap=false,
    ).font(ui_font(9.0, 500)).foreground(ui_muted()),
    plus,
    close,
  ], spacing=8.0, align=@style.CrossAlign::Center).frame(
    width=(width - 24.0).max(0.0),
    height=float_header_height,
  )
  @views.container(
    @views.padding_xy(content, horizontal=12.0),
    width~,
    height=float_header_height,
    background=ui_surface_alt(),
    corner_radius=10.0,
    padding=0.0,
  )
  .on_drag(fn(event) {
    FloatHeaderDrag(event.phase, event.translation.x, event.translation.y)
  })
  .cursor(
    @core.CursorStyle::Icon(
      if model.float.dragging {
        @core.CursorIcon::CursorGrabbing
      } else {
        @core.CursorIcon::CursorGrab
      },
    ),
  )
  .accessibility_label(
    tr(model.lang, "Drag floating workspace header", "拖动浮岛工作区标题栏"),
  )
}

///|
fn float_menu_button(
  label : String,
  icon : @style.IconName,
  msg : Msg,
) -> @moui.View[Msg] {
  @views.button(
    label,
    on_click=msg,
    style=float_menu_button_style(),
    icon=Some(icon),
    width=(float_menu_width - 20.0),
    height=30.0,
    label_align=@core.TextAlign::TextStart,
  )
  .semantics_role(@core.SemanticsRole::MenuItem)
}

///|
fn float_menu(model : Model) -> @moui.View[Msg] {
  let browser = @views.button(
    tr(model.lang, "Browser · Later", "浏览器 · 即将支持 / Later"),
    style=float_menu_disabled_style(),
    icon=Some(@style.IconName::Eye),
    width=(float_menu_width - 20.0),
    height=30.0,
    label_align=@core.TextAlign::TextStart,
  )
  .disabled(disabled=true)
  .semantics_role(@core.SemanticsRole::MenuItem)
  .semantics_description(
    tr(
      model.lang,
      "Browser is not available in this build.",
      "此版本暂不支持浏览器。",
    ),
  )
  .accessibility_label(
    tr(model.lang, "Browser, coming later", "浏览器，即将支持"),
  )
  @views.container(
    @views.padding(
      @views.column([
        @views.text(
          tr(model.lang, "New", "新建"),
          align=@core.TextAlign::TextStart,
        ).font(ui_font(9.0, 600)).foreground(ui_dim()),
        float_menu_button(
          tr(model.lang, "New note", "新建笔记"),
          @style.IconName::FileNew,
          FloatNewNote,
        ),
        float_menu_button(
          tr(model.lang, "New Agent conversation", "新建 Agent 对话"),
          @style.IconName::Chat,
          FloatNewAgent,
        ),
        float_menu_button(
          tr(model.lang, "New terminal", "新建终端"),
          @style.IconName::CodeInline,
          FloatNewTerminal,
        ),
        browser,
      ], spacing=2.0, align=@style.CrossAlign::Start),
      8.0,
    ),
    width=float_menu_width,
    height=float_menu_height,
    background=ui_surface(),
    corner_radius=5.0,
    border=Some(ui_edge(ui_border())),
    padding=0.0,
  )
  .semantics_role(@core.SemanticsRole::Menu)
  .accessibility_label(tr(model.lang, "New tab menu", "新建标签菜单"))
}

///|
fn float_empty_state(
  model : Model,
  width : Double,
  height : Double,
) -> @moui.View[Msg] {
  @views.column([
    @views.text(
      tr(model.lang, "No open tabs", "尚无打开标签"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(18.0, 600)).foreground(ui_text_color()),
    @views.text(
      tr(
        model.lang,
        "Open a local note, the current Agent conversation, or the focused terminal from the + menu.",
        "从 + 菜单打开本地笔记、当前 Agent 对话或已聚焦的终端。",
      ),
      width~,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(13.0, 400)).foreground(ui_muted()),
    @views.row([
      ui_primary(tr(model.lang, "New note", "新建笔记"), FloatNewNote),
      ui_ghost(tr(model.lang, "Agent", "Agent"), FloatNewAgent),
      ui_ghost(tr(model.lang, "Terminal", "终端"), FloatNewTerminal),
      @views.spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~),
  ], spacing=10.0, align=@style.CrossAlign::Start).frame(
    width~,
    height~,
  )
}

///|
fn float_note_state(note : FloatNote, lang : Lang) -> (String, @core.Color) {
  match note.state {
    FloatNoteSaved => (tr(lang, "Saved", "已保存"), ui_dim())
    FloatNoteSaving => (tr(lang, "Saving…", "正在保存…"), ui_muted())
    FloatNoteFailed(_) => (tr(lang, "Save failed", "保存失败"), ui_danger())
  }
}

///|
fn float_note_editor_lines(height : Double) -> Int32 {
  if height < 120.0 {
    4
  } else if height < 180.0 {
    6
  } else if height < 240.0 {
    9
  } else if height < 320.0 {
    12
  } else if height < 400.0 {
    16
  } else {
    20
  }
}

///|
fn float_note_pane(
  model : Model,
  note : FloatNote,
  width : Double,
  height : Double,
) -> @moui.View[Msg] {
  let (state_label, state_tone) = float_note_state(note, model.lang)
  let title_width = (width - 160.0).max(180.0)
  let title_row = @views.row([
    lucide_icon("file-text", size=13.0, color=ui_dim()),
    @views.text_field(
      note.title,
      on_input=fn(value) { FloatNoteTitleDraft(value) },
      placeholder=tr(model.lang, "Note title", "笔记标题"),
      style=ui_field_style(),
      width=title_width,
      height=30.0,
    ).accessibility_label(tr(model.lang, "Note title", "笔记标题")),
    @views.spacer(weight=1.0),
    @views.text(
      state_label,
      width=90.0,
      align=@core.TextAlign::TextEnd,
      wrap=false,
    ).font(ui_font(9.0, 500)).foreground(state_tone),
  ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~, height=30.0)
  let meta_row = @views.row([
    ui_mono(note.file_name, 9.5),
    @views.spacer(weight=1.0),
    @views.text(
      tr(model.lang, "local · one file per note", "本地 · 每条笔记一个文件"),
      align=@core.TextAlign::TextEnd,
    ).font(ui_font(9.0, 400)).foreground(ui_dim()),
  ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~, height=14.0)
  let message_extra = if model.float.message != "" { 18.0 } else { 0.0 }
  let reserve = 30.0 + 14.0 + 16.0 + 24.0 + message_extra
  let editor_height = (height - reserve).max(80.0)
  let lines = float_note_editor_lines(editor_height)
  let editor = @views.text_area(
    note.content,
    on_input=fn(value) { FloatNoteContentDraft(value) },
    placeholder=tr(
      model.lang,
      "Plain text or Markdown. Autosaves locally.",
      "纯文本或 Markdown。本地自动保存。",
    ),
    lines~,
    variant=@style.TextFieldVariant::Filled,
    theme=field_theme(),
    width~,
    line_height=20.0,
  ).accessibility_label(tr(model.lang, "Note content", "笔记正文"))
  let path = match float_note_path_in(float_notes_dir(), note.file_name) {
    Some(value) => value
    None => note.file_name
  }
  let children : Array[@moui.View[Msg]] = [
    title_row,
    meta_row,
  ]
  if model.float.message != "" {
    children.push(
      @views.text(
        model.float.message,
        width~,
        align=@core.TextAlign::TextStart,
        wrap=false,
      ).font(ui_font(9.0, 400)).foreground(ui_danger()),
    )
  }
  children.push(editor)
  children.push(
    @views.text(
      path,
      width~,
      align=@core.TextAlign::TextStart,
      wrap=false,
    ).font(mono_font(8.5, 400)).foreground(ui_dim()),
  )
  @views.column(children, spacing=8.0, align=@style.CrossAlign::Start).frame(
    width~,
    height~,
  )
}

///|
fn float_agent_chat(model : Model) -> ChatProjection? {
  if model.selected_chat == "" {
    return None
  }
  chat_by_id(model.chats, model.selected_chat)
}

///|
fn float_agent_chat_state(model : Model, chat : ChatProjection) -> String {
  if model.chat_session_state != "" {
    model.chat_session_state
  } else {
    chat.agent_state
  }
}

///|
fn float_agent_status(model : Model) -> (String, @core.Color) {
  match float_agent_chat(model) {
    Some(chat) => {
      let state = float_agent_chat_state(model, chat)
      if state != "" {
        (state, status_tone(state))
      } else if chat.state != "" {
        (chat.state, status_tone(chat.state))
      } else {
        (tr(model.lang, "idle", "空闲"), ui_muted())
      }
    }
    None =>
      match model.agent.session {
        Some(record) =>
          if record.state == "" {
            (tr(model.lang, "session", "会话"), ui_muted())
          } else {
            (record.state, ui_success())
          }
        None => (tr(model.lang, "no session", "无会话"), ui_dim())
      }
  }
}

///|
fn float_agent_session_active(model : Model) -> Bool {
  match float_agent_chat(model) {
    Some(chat) => chat_session_active(float_agent_chat_state(model, chat))
    None => model.agent.session is Some(_)
  }
}

///|
fn float_agent_session_label(model : Model) -> String {
  match float_agent_chat(model) {
    Some(chat) =>
      if chat.agent_session_id == "" {
        tr(model.lang, "(none)", "（无）")
      } else {
        terminal_session_label(chat.agent_session_id)
      }
    None =>
      match model.agent.session {
        Some(record) => terminal_session_label(record.id)
        None => tr(model.lang, "(none)", "（无）")
      }
  }
}

///|
fn float_agent_message_entry(
  model : Model,
  message : @contracts.ChatMessage,
  bot : BotIdentity,
  width : Double,
) -> @moui.View[Msg] {
  let when = workroom_clock(message.created_at)
  let (label, role, tone, body_tone, font_size) =
    if message.role == @contracts.CHAT_MESSAGE_ROLE_USER {
      (
        tr(model.lang, "You", "你"),
        tr(model.lang, "started the work", "发起工作"),
        ui_text_color(),
        ui_text_color(),
        11.5,
      )
    } else if message.role == @contracts.CHAT_MESSAGE_ROLE_ASSISTANT {
      (
        bot.name,
        tr(model.lang, "agent", "智能体"),
        ui_text_color(),
        ui_text_color(),
        11.5,
      )
    } else {
      (
        tr(model.lang, "System", "系统"),
        "",
        ui_dim(),
        ui_muted(),
        9.5,
      )
    }
  @views.column([
    @views.row([
      @views.text(label, align=@core.TextAlign::TextStart).font(
        ui_font(9.5, 620),
      ).foreground(tone),
      @views.text(role, align=@core.TextAlign::TextStart).font(
        ui_font(8.5, 400),
      ).foreground(ui_dim()),
      @views.spacer(weight=1.0),
      if when == "" { ui_meta("") } else { ui_mono(when, 8.0) },
    ], spacing=6.0, align=@style.CrossAlign::Center).frame(width~),
    @views.text(
      message.body,
      width~,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(font_size, 400)).foreground(body_tone),
  ], spacing=4.0, align=@style.CrossAlign::Start).frame(width~)
}

///|
fn float_agent_pane(
  model : Model,
  width : Double,
  height : Double,
) -> @moui.View[Msg] {
  let chat = float_agent_chat(model)
  let bot = active_bot_identity(model)
  let (status, status_tone) = float_agent_status(model)
  let session_label = float_agent_session_label(model)
  let title = match chat {
    Some(record) => record.title
    None => tr(model.lang, "Agent conversation", "Agent 对话")
  }
  let header = @views.row([
    lucide_icon("message-circle", size=13.0, color=ui_muted()),
    @views.text(bot.name, align=@core.TextAlign::TextStart).font(
      ui_font(11.0, 620),
    ).foreground(ui_text_color()),
    @views.text(
      title,
      width=(width - 250.0).max(80.0),
      align=@core.TextAlign::TextStart,
      wrap=false,
    ).font(ui_font(9.0, 400)).foreground(ui_dim()),
    @views.spacer(weight=1.0),
    ui_state_pill(status, status_tone),
    ui_mono(session_label, 8.5),
  ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~, height=24.0)
  let session_active = float_agent_session_active(model)
  let needs_session = !session_active
  let notice_height = if needs_session { 58.0 } else { 0.0 }
  // Reserve the header, two hairlines, the composer and action row, the
  // optional empty-session notice, and every 8pt column gap. Reserving only
  // the controls themselves lets the action row spill past the overlay edge.
  let fixed_height = if needs_session { 198.0 } else { 132.0 }
  let transcript_height = (height - fixed_height).max(36.0)
  let transcript_children : Array[@moui.View[Msg]] = []
  match chat {
    Some(record) => {
      if model.chat_messages.is_empty() {
        transcript_children.push(
          @views.text(
            if !model.chat_messages_loaded {
              tr(model.lang, "Loading Chat messages...", "正在加载对话消息...")
            } else {
              tr(
                model.lang,
                "No messages yet. Send the first message below.",
                "尚无消息。请在下方发送第一条消息。",
              )
            },
            width~,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(11.0, 400)).foreground(ui_dim()),
        )
      } else {
        for message in model.chat_messages {
          if message.chat_id == record.id {
            transcript_children.push(
              float_agent_message_entry(model, message, bot, width),
            )
          }
        }
      }
      if model.chat_messages_in_flight && !model.chat_messages.is_empty() {
        transcript_children.push(
          ui_meta(tr(model.lang, "Loading more messages...", "正在加载更多消息...")),
        )
      }
      let live = chat_live_tail(model)
      if live != "" {
        transcript_children.push(
          @views.column([
            @views.text(
              bot.name + tr(model.lang, " · live", " · 实时"),
              align=@core.TextAlign::TextStart,
            ).font(ui_font(9.5, 620)).foreground(ui_text_color()),
            @views.text(
              live,
              width~,
              align=@core.TextAlign::TextStart,
              wrap=true,
            ).font(ui_font(11.5, 400)).foreground(ui_text_color()),
          ], spacing=4.0, align=@style.CrossAlign::Start).frame(width~),
        )
      }
      if model.chat_pending_decision != "" {
        transcript_children.push(
          @views.text(
            tr(
              model.lang,
              "A Decision needs the owner. Open Inbox to review it.",
              "有一项决策需要所有者处理。请打开收件箱查看。",
            ),
            width~,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(9.5, 400)).foreground(ui_warning()),
        )
      }
    }
    None => {
      let transcript = model.agent.transcript.trim_end().to_owned()
      let launch = model.agent.launch_prompt.trim().to_owned()
      if launch != "" {
        transcript_children.push(
          @views.text(
            tr(model.lang, "You · ", "你 · ") + launch,
            width~,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(10.0, 400)).foreground(ui_muted()),
        )
      }
      for prompt in model.agent.sent_prompts {
        transcript_children.push(
          @views.text(
            tr(model.lang, "You · ", "你 · ") + prompt,
            width~,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(10.0, 400)).foreground(ui_muted()),
        )
      }
      if transcript == "" {
        transcript_children.push(
          @views.text(
            tr(
              model.lang,
              "No reply yet. Replies appear here as continuous text.",
              "尚无回复。回复会在这里以连续正文显示。",
            ),
            width~,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(12.0, 400)).foreground(ui_dim()),
        )
      } else {
        transcript_children.push(
          @views.text(
            transcript,
            width~,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(12.0, 400)).foreground(ui_text_color()),
        )
      }
    }
  }
  let transcript_body = @views.column(
    transcript_children,
    spacing=8.0,
    align=@style.CrossAlign::Start,
  ).frame(width~)
  let transcript_view = @views.scroll_view(
    transcript_body,
    width~,
    height=transcript_height,
    request=@core.ScrollRequest::new(
      id=model.scroll_epoch + 401,
      offset=@core.Point::new(x=0.0, y=0.0),
    ),
    shows_indicator=true,
  )
  let composer = @views.text_area(
    model.agent.input,
    on_input=fn(value) { AgentInputDraft(value) },
    on_submit=Some(ComposerSend),
    placeholder=tr(
      model.lang,
      "Reply in this Agent conversation. Sending uses the current Bot.",
      "在此 Agent 对话中回复。发送使用当前 Bot。",
    ),
    lines=2,
    variant=@style.TextFieldVariant::Filled,
    theme=field_theme(),
    width~,
    line_height=18.0,
  ).accessibility_label(tr(model.lang, "Agent reply", "Agent 回复"))
  let composer_actions : Array[@moui.View[Msg]] = [
    ui_primary(tr(model.lang, "Send", "发送"), ComposerSend),
  ]
  if session_active {
    composer_actions.push(
      ui_danger_ghost(tr(model.lang, "Stop", "停止"), AgentStopSession),
    )
  }
  composer_actions.push(
    @views.text(
      tr(model.lang, "↵ send · same session", "↵ 发送 · 同一会话"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(9.0, 400)).foreground(ui_dim()),
  )
  composer_actions.push(@views.spacer(weight=1.0))
  let children : Array[@moui.View[Msg]] = [
    header,
    ui_divider_soft(),
  ]
  if needs_session {
    let notice_text = match chat {
      Some(_) =>
        tr(
          model.lang,
          "This Chat has no running Agent session. Start it to continue in the same Chat.",
          "此对话没有运行中的智能体会话。启动后可在同一对话中继续。",
        )
      None =>
        tr(
          model.lang,
          "No active Agent session. This tab reuses the current Bot and composer; send below to start the existing Agent path.",
          "尚无活跃 Agent 会话。此标签复用当前 Bot 与输入框；在下方发送即可启动现有 Agent 路径。",
        )
    }
    let notice_action = match chat {
      Some(_) =>
        ui_ghost_small(
          tr(model.lang, "Start session", "启动会话"),
          ChatStartSession,
        )
      None => ui_ghost_small(tr(model.lang, "Start Chat", "开始对话"), NewChat)
    }
    children.push(
      @views.container(
        @views.padding_xy(
          @views.row([
            @views.text(
              notice_text,
              width=(width - 120.0).max(180.0),
              align=@core.TextAlign::TextStart,
              wrap=true,
            ).font(ui_font(9.5, 400)).foreground(ui_muted()),
            @views.spacer(weight=1.0),
            notice_action,
          ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~),
          horizontal=10.0,
        ),
        height=notice_height,
        background=ui_surface_alt(),
        corner_radius=4.0,
        border=Some(ui_edge(ui_border_soft())),
        padding=0.0,
      ),
    )
  }
  children.push(transcript_view)
  children.push(ui_divider_soft())
  children.push(composer)
  children.push(
    @views.row(
      composer_actions,
      spacing=8.0,
      align=@style.CrossAlign::Center,
    ).frame(width~),
  )
  @views.column(children, spacing=8.0, align=@style.CrossAlign::Start).frame(
    width~,
    height~,
  )
}

///|
fn float_terminal_columns(width : Double) -> Int32 {
  if width < 560.0 {
    48
  } else if width < 720.0 {
    64
  } else {
    96
  }
}

///|
fn float_terminal_pane(
  model : Model,
  width : Double,
  height : Double,
) -> @moui.View[Msg] {
  match model.project.workspace {
    None =>
      @views.column([
        @views.row([
          lucide_icon("terminal", size=13.0, color=ui_dim()),
          @views.text(
            tr(model.lang, "Terminal", "终端"),
            align=@core.TextAlign::TextStart,
          ).font(ui_font(11.0, 620)).foreground(ui_text_color()),
          @views.spacer(weight=1.0),
          ui_state_pill(tr(model.lang, "no project", "无项目"), ui_dim()),
        ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~, height=24.0),
        ui_divider_soft(),
        @views.text(
          tr(
            model.lang,
            "Open a project first, then open its terminal. This tab does not invent a second terminal backend.",
            "请先打开项目，然后打开其终端。此标签不会创建第二套终端后端。",
          ),
          width~,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(12.0, 400)).foreground(ui_muted()),
        if model.float.message == "" {
          @views.empty()
        } else {
          @views.text(
            model.float.message,
            width~,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(10.0, 400)).foreground(ui_warning())
        },
      ], spacing=8.0, align=@style.CrossAlign::Start).frame(
        width~,
        height~,
      )
    Some(record) => {
      let (status, state_tone) = (
        terminal_state_label(model.project.terminal_state, model.lang),
        terminal_state_tone(model.project.terminal_state),
      )
      let session_label = if model.project.terminal_id == "" {
        tr(model.lang, "(none)", "（无）")
      } else {
        terminal_session_label(model.project.terminal_id)
      }
      let header = @views.row([
        lucide_icon("terminal", size=13.0, color=ui_muted()),
        @views.text(record.name, align=@core.TextAlign::TextStart).font(
          ui_font(11.0, 620),
        ).foreground(ui_text_color()),
        @views.text(
          tr(model.lang, "shared PTY", "共享 PTY"),
          align=@core.TextAlign::TextStart,
        ).font(ui_font(9.0, 400)).foreground(ui_dim()),
        @views.spacer(weight=1.0),
        ui_state_pill(status, state_tone),
        ui_mono(session_label, 8.5),
      ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~, height=24.0)
      let children : Array[@moui.View[Msg]] = [
        header,
        ui_divider_soft(),
      ]
      if model.project.terminal_state == TerminalClosed {
        children.push(
          @views.row([
            @views.text(
              tr(
                model.lang,
                "Terminal is not open. Open it here; it uses the same PTY as the Manage focus view.",
                "终端尚未打开。在此打开；它将使用与管理页聚焦视图相同的 PTY。",
              ),
              width=(width - 120.0).max(180.0),
              align=@core.TextAlign::TextStart,
              wrap=true,
            ).font(ui_font(10.0, 400)).foreground(ui_muted()),
            @views.spacer(weight=1.0),
            ui_primary(
              tr(model.lang, "Open terminal", "打开终端"),
              FloatOpenTerminal,
            ),
          ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~),
        )
      } else {
        let transcript_height = terminal_float_transcript_height(model, height)
        let text = model.project.terminal_text
        if text == "" && model.project.terminal_state != TerminalRunning {
          children.push(
            @views.text(
              if model.project.terminal_state == TerminalOpening {
                tr(model.lang, "Opening the terminal…", "正在打开终端…")
              } else {
                tr(model.lang, "No terminal output yet.", "尚无终端输出。")
              },
              width~,
              align=@core.TextAlign::TextStart,
              wrap=true,
            ).font(ui_font(10.0, 400)).foreground(ui_dim()),
          )
        } else if text == "" {
          children.push(
            @views.text(
              tr(
                model.lang,
                "No output yet; the PTY is running.",
                "尚无输出；PTY 正在运行。",
              ),
              width~,
              align=@core.TextAlign::TextStart,
              wrap=true,
            ).font(ui_font(10.0, 400)).foreground(ui_dim()),
          )
        } else {
          children.push(
            terminal_transcript_view(
              model,
              width~,
              height=transcript_height,
              columns=float_terminal_columns(width),
              scroll_id_offset=301,
            ),
          )
        }
        if model.project.terminal_error != "" {
          children.push(
            @views.text(
              model.project.terminal_error,
              width~,
              align=@core.TextAlign::TextStart,
              wrap=true,
            ).font(ui_font(9.5, 400)).foreground(ui_danger()),
          )
        }
        if model.project.terminal_state == TerminalEnded ||
          model.project.terminal_state == TerminalFailed {
          children.push(
            @views.row([
              ui_danger_ghost(
                tr(model.lang, "Reconnect", "重新连接"),
                FloatTerminalReconnect,
              ),
              @views.text(
                if model.project.terminal_state == TerminalEnded {
                  tr(model.lang, "the shell exited (EOF)", "shell 已退出（EOF）")
                } else {
                  tr(model.lang, "the session was lost", "会话已丢失")
                },
                align=@core.TextAlign::TextStart,
              ).font(ui_font(9.0, 400)).foreground(ui_muted()),
              @views.spacer(weight=1.0),
            ], spacing=8.0, align=@style.CrossAlign::Center).frame(width~),
          )
        }
        children.push(
          @views.column([
            terminal_input_field(
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
                width~,
                height=30.0,
              ),
            ).accessibility_label(
              tr(model.lang, "Terminal command", "终端命令"),
            ),
            @views.row([
              ui_primary(tr(model.lang, "Send", "发送"), ProjectTerminalSend),
              ui_danger_ghost(
                tr(model.lang, "Stop", "停止"),
                ProjectTerminalStop,
              ),
              ui_ghost_small(tr(model.lang, "Clear", "清空"), ProjectTerminalClear),
              ui_ghost_small(tr(model.lang, "Close", "关闭"), ProjectTerminalClose),
              @views.spacer(weight=1.0),
            ], spacing=6.0, align=@style.CrossAlign::Center).frame(width~),
          ], spacing=6.0, align=@style.CrossAlign::Start).frame(width~),
        )
      }
      @views.column(children, spacing=8.0, align=@style.CrossAlign::Start).frame(
        width~,
        height~,
      )
    }
  }
}

///|
fn float_body(model : Model, width : Double, height : Double) -> @moui.View[Msg] {
  let inner_width = (width - float_body_padding * 2.0).max(0.0)
  let inner_height = (height - float_body_padding * 2.0).max(0.0)
  let body = match float_active_tab(model.float) {
    Some(tab) =>
      match tab.kind {
        FloatNote =>
          match float_note_by_id(model.float, tab.note_id) {
            Some(note) => float_note_pane(model, note, inner_width, inner_height)
            None => float_empty_state(model, inner_width, inner_height)
          }
        FloatAgent => float_agent_pane(model, inner_width, inner_height)
        FloatTerminal => float_terminal_pane(model, inner_width, inner_height)
      }
    None => float_empty_state(model, inner_width, inner_height)
  }
  @views.container(
    @views.padding(body, float_body_padding),
    width~,
    height~,
    background=clear_color(),
    padding=0.0,
  )
}

///|
fn float_resize_corner(model : Model) -> @moui.View[Msg] {
  @views.container(
    lucide_icon("maximize", size=10.0, color=ui_dim()),
    width=18.0,
    height=18.0,
    background=clear_color(),
    corner_radius=3.0,
    padding=0.0,
  )
  .on_drag(fn(event) {
    FloatResizeDrag(event.phase, event.translation.x, event.translation.y)
  })
  .cursor(@core.CursorStyle::Icon(@core.CursorIcon::CursorNwseResize))
  .accessibility_label(
    tr(model.lang, "Resize floating workspace", "调整浮岛工作区大小"),
  )
}

///|
fn float_workspace_overlay(model : Model) -> @moui.View[Msg] {
  let width = model.float.width
  let height = model.float.height
  let inner_width = (width - 24.0).max(0.0)
  let tabs_height = float_tabs_height(model.float, inner_width)
  let body_y = float_header_height + 1.0 + tabs_height
  let body_height = (height - body_y).max(0.0)
  let placed : Array[@views.Placed[Msg]] = [
    @views.place(
      float_header(model, width),
      x=0.0,
      y=0.0,
      width~,
      height=float_header_height,
    ),
    @views.place(
      ui_divider(),
      x=0.0,
      y=float_header_height,
      width~,
      height=1.0,
    ),
  ]
  if tabs_height > 0.0 {
    placed.push(
      @views.place(
        @views.padding_xy(
          float_tabs_view(model, inner_width),
          horizontal=12.0,
        ),
        x=0.0,
        y=float_header_height + 1.0,
        width~,
        height=tabs_height,
      ),
    )
  }
  placed.push(
    @views.place(
      float_body(model, width, body_height),
      x=0.0,
      y=body_y,
      width~,
      height=body_height,
    ),
  )
  if model.float.menu_open {
    placed.push(
      @views.place(
        float_menu(model),
        x=(width - float_menu_width - 14.0).max(12.0),
        y=body_y + 6.0,
        width=float_menu_width,
        height=float_menu_height,
      ),
    )
  }
  placed.push(
    @views.place(
      float_resize_corner(model),
      x=(width - 22.0).max(0.0),
      y=(height - 22.0).max(0.0),
      width=18.0,
      height=18.0,
    ),
  )
  @views.container(
    @views.stage(width~, height~, placed),
    width~,
    height~,
    background=ui_surface(),
    corner_radius=10.0,
    border=Some(ui_edge(ui_border())),
    padding=0.0,
  )
  .shadow(
    @core.ShadowStyle::new(
      color=ui_shadow(),
      offset=@core.Point::new(x=0.0, y=10.0),
      blur_radius=22.0,
      spread=0.0,
    ),
  )
  .theme(app_theme())
}

///|
fn float_window_layer(
  model : Model,
  shell : @moui.View[Msg],
) -> @moui.View[Msg] {
  if !model.float.open {
    return shell
  }
  let overlay = float_workspace_overlay(model)
  @views.stage(
    width=ui_window_width,
    height=ui_window_height,
    [
      @views.place(
        shell,
        x=0.0,
        y=0.0,
        width=ui_window_width,
        height=ui_window_height,
      ),
      @views.place(
        overlay,
        x=model.float.x,
        y=model.float.y,
        width=model.float.width,
        height=model.float.height,
      ),
    ],
  ).theme(app_theme())
}
