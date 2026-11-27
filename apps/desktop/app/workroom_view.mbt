///|
/// Chat-first workroom. The main island is one 739pt work column, a hairline,
/// and a 292pt details rail. Projects, machines, executors and sessions stay in
/// the rail; they are context for this Chat, not peer destinations.

///|
fn workroom_clock(value : String) -> String {
  if value == "" {
    return ""
  }
  let stamp = compact_time(value)
  if stamp.length() >= 16 {
    stamp[11:16].to_owned()
  } else {
    stamp
  }
}

///|
fn workroom_status(model : Model) -> String {
  if model.agent.state_text != "" {
    return model.agent.state_text
  }
  match model.agent.session {
    Some(record) => record.state
    None => model.host.link.label_in(model.lang)
  }
}

///|
fn workroom_updated(model : Model, chat : ChatIdentity?) -> String {
  match chat {
    Some(record) =>
      if record.updated_at != "" {
        compact_time(record.updated_at)
      } else {
        workroom_clock(record.updated_at)
      }
    None =>
      match model.agent.session {
        Some(record) =>
          if session_recency(record) != "" {
            compact_time(session_recency(record))
          } else {
            ""
          }
        None => ""
      }
  }
}

///|
fn workroom_bot_items(model : Model) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = []
  if model.bots.is_empty() {
    let bot = active_bot_identity(model)
    items.push(
      @views.MenuItem::new(
        id=bot.id,
        label=bot.name,
        message=SelectComposerBot(bot.id),
      ),
    )
  } else {
    for record in model.bots {
      items.push(
        @views.MenuItem::new(
          id=record.id,
          label=bot_name(record),
          message=SelectComposerBot(record.id),
        ),
      )
    }
  }
  items
}

///|
fn workroom_header(
  model : Model,
  chat : ChatIdentity?,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let title = if model.composing_new_chat {
    tr(model.lang, "New Chat", "新对话")
  } else {
    match chat {
      Some(record) => record.title
      None => tr(model.lang, "No Chat yet", "尚无对话")
    }
  }
  let updated = workroom_updated(model, chat)
  let workspace_name = workspace_context_name(model, model.agent.workspace_id)
  let meta : Array[@moui.View[Msg]] = [
    @views.text(bot.name, align=@core.TextAlign::TextStart).font(
      ui_font(10.0, 550),
    ).foreground(ui_muted()),
  ]
  if workspace_name != "" {
    meta.push(ui_meta("·"))
    meta.push(
      @views.text(workspace_name, align=@core.TextAlign::TextStart).font(
        ui_font(10.0, 400),
      ).foreground(ui_dim()),
    )
  }
  if updated != "" {
    meta.push(ui_meta("·"))
    meta.push(ui_meta(updated + tr(model.lang, " updated", " 更新")))
  }
  let avatar = @views.container(
    @views.text(
      bot_initial(bot.name),
      align=@core.TextAlign::TextCenter,
    ).font(ui_font(7.5, 600)).foreground(ui_on_ink()),
    width=16.0,
    height=16.0,
    background=ui_ink(),
    corner_radius=8.0,
    padding=0.0,
  )
  let bot_chip = @views.container(
    @views.padding_xy(
      @views.row([
        avatar,
        @views.text(bot.name, align=@core.TextAlign::TextStart).font(
          ui_font(10.0, 550),
        ).foreground(ui_muted()),
      ], spacing=5.0, align=@style.CrossAlign::Center),
      horizontal=0.0,
    ),
    height=20.0,
    padding=0.0,
  ).on_tap(OpenBotDetail(bot.id)).cursor(
    @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
  )
  @views.container(
    @views.padding_edges(
      @views.column([
        @views.text(
          tr(model.lang, "Work thread", "工作线程"),
          align=@core.TextAlign::TextStart,
        ).font(ui_font(9.0, 650)).foreground(ui_dim()),
        @views.row([
          @views.text(
            title,
            width=430.0,
            align=@core.TextAlign::TextStart,
            wrap=false,
          ).font(ui_font(18.0, 650)).foreground(ui_text_color()),
          ui_tag(workroom_status(model)),
          @views.spacer(weight=1.0),
          bot_chip,
        ], spacing=9.0, align=@style.CrossAlign::Center).frame(width=683.0),
        @views.row(meta, spacing=6.0, align=@style.CrossAlign::Center).frame(
          width=683.0,
        ),
      ], spacing=7.0, align=@style.CrossAlign::Start).frame(width=683.0),
      top=22.0,
      right=28.0,
      bottom=16.0,
      left=28.0,
    ),
    height=96.0,
    padding=0.0,
  )
}

///|
fn workroom_user_entry(
  model : Model,
  prompt : String,
  when : String,
) -> @moui.View[Msg] {
  let body = @views.text(
    prompt,
    width=655.0,
    align=@core.TextAlign::TextStart,
    wrap=true,
  ).font(ui_font(13.0, 400)).foreground(ui_text_color())
  let wash = @views.container(
    @views.padding_edges(
      @views.column([
        @views.row([
          @views.text(tr(model.lang, "You", "你"), align=@core.TextAlign::TextStart).font(
            ui_font(11.0, 620),
          ).foreground(ui_text_color()),
          @views.text(
            tr(model.lang, "started the work", "发起工作"),
            align=@core.TextAlign::TextStart,
          ).font(ui_font(9.5, 400)).foreground(ui_dim()),
          @views.spacer(weight=1.0),
          if when == "" { ui_meta("") } else { ui_mono(when, 8.5) },
        ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=655.0),
        body,
      ], spacing=7.0, align=@style.CrossAlign::Start).frame(width=655.0),
      top=10.0,
      right=12.0,
      bottom=10.0,
      left=12.0,
    ),
    background=ui_surface_alt(),
    corner_radius=0.0,
    padding=0.0,
  )
  @views.row([
    @views.container(@views.empty(), width=2.0, background=ui_ink(), padding=0.0),
    wash,
  ], spacing=0.0, align=@style.CrossAlign::Stretch).frame(width=683.0)
}

///|
fn workroom_assistant_entry(
  model : Model,
  chat : ChatIdentity?,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let transcript = model.agent.transcript.trim_end().to_owned()
  let body = if transcript == "" {
    @views.text(
      tr(
        model.lang,
        "No reply yet. Replies appear here as continuous text.",
        "尚无回复。回复会在这里以连续正文显示。",
      ),
      width=683.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(12.0, 400)).foreground(ui_dim())
  } else {
    @views.text(
      transcript,
      width=683.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(13.0, 400)).foreground(ui_text_color())
  }
  let when = match chat {
    Some(record) => workroom_clock(record.updated_at)
    None => ""
  }
  @views.column([
    @views.row([
      @views.text(bot.name, align=@core.TextAlign::TextStart).font(
        ui_font(11.0, 620),
      ).foreground(ui_text_color()),
      @views.text(
        tr(model.lang, "assistant", "助手"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(9.5, 400)).foreground(ui_dim()),
      @views.spacer(weight=1.0),
      if when == "" { ui_meta("") } else { ui_mono(when, 8.5) },
    ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=683.0),
    body,
  ], spacing=7.0, align=@style.CrossAlign::Start).frame(width=683.0)
}

///|
fn workroom_pending_item(model : Model) -> @moui.View[Msg]? {
  if model.agent.pending_decision == "" {
    return None
  }
  Some(
    @views.container(
      @views.padding_edges(
        @views.row([
          @views.container(@views.empty(), width=2.0, background=ui_warning(), padding=0.0),
          @views.padding_edges(
            @views.column([
              @views.row([
                @views.lucide_icon("alert-triangle", size=13.0, color=ui_warning()),
                @views.text(
                  tr(model.lang, "Needs confirmation", "待确认"),
                  align=@core.TextAlign::TextStart,
                ).font(ui_font(10.5, 620)).foreground(ui_warning()),
                @views.spacer(weight=1.0),
                ui_mono(tr(model.lang, "blocking", "阻塞项"), 8.5),
              ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=659.0),
              @views.text(
                model.agent.pending_decision,
                width=659.0,
                align=@core.TextAlign::TextStart,
                wrap=true,
              ).font(ui_font(10.0, 400)).foreground(ui_muted()),
              @views.row([
                ui_ghost_small(
                  tr(model.lang, "Open Inbox", "打开收件箱"),
                  SelectPage(Inbox),
                ),
                @views.spacer(weight=1.0),
              ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=659.0),
            ], spacing=7.0, align=@style.CrossAlign::Start).frame(width=659.0),
            top=10.0,
            right=11.0,
            bottom=10.0,
            left=11.0,
          ),
        ], spacing=0.0, align=@style.CrossAlign::Stretch),
      ),
      width=683.0,
      background=ui_surface(),
      corner_radius=3.0,
      border=Some(ui_edge(ui_border_soft())),
      padding=0.0,
    ),
  )
}

///|
fn workroom_activity_row(
  icon : String,
  label : String,
  when : String,
) -> @moui.View[Msg] {
  @views.row([
    @views.lucide_icon(icon, size=12.0, color=ui_dim()),
    @views.text(label, align=@core.TextAlign::TextStart).font(
      ui_font(9.5, 400),
    ).foreground(ui_muted()),
    @views.spacer(weight=1.0),
    if when == "" { ui_meta("") } else { ui_mono(when, 8.5) },
  ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=683.0)
}

///|
fn workroom_activity(
  model : Model,
  chat : ChatIdentity?,
) -> @moui.View[Msg] {
  let rows : Array[@moui.View[Msg]] = []
  match model.agent.session {
    Some(record) => {
      let started = workroom_clock(record.started_at)
      if started != "" {
        rows.push(
          workroom_activity_row(
            "play",
            tr(model.lang, "Session started", "会话已启动"),
            started,
          ),
        )
      }
      if record.turns > 0 || record.chunks > 0 {
        rows.push(
          workroom_activity_row(
            "activity",
            record.turns.to_string() +
            tr(model.lang, " turns · ", " 轮 · ") +
            record.chunks.to_string() +
            tr(model.lang, " chunks", " 个片段"),
            workroom_clock(record.updated_at),
          ),
        )
      }
      if !record.artifacts.is_empty() {
        rows.push(
          workroom_activity_row(
            "file",
            record.artifacts.length().to_string() +
            tr(model.lang, " artifacts", " 个产物"),
            "",
          ),
        )
      }
    }
    None => ()
  }
  match chat {
    Some(record) =>
      if record.is_fallback {
        ()
      } else if record.updated_at != "" {
        rows.push(
          workroom_activity_row(
            "message-circle",
            tr(model.lang, "Chat projection updated", "对话投影已更新"),
            workroom_clock(record.updated_at),
          ),
        )
      }
    None => ()
  }
  let body : Array[@moui.View[Msg]] = [
    @views.row([
      @views.lucide_icon("list", size=12.0, color=ui_dim()),
      @views.text(tr(model.lang, "Activity", "活动"), align=@core.TextAlign::TextStart).font(
        ui_font(9.5, 570),
      ).foreground(ui_muted()),
      @views.spacer(weight=1.0),
      ui_mono(tr(model.lang, "this session", "当前会话"), 8.5),
    ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=683.0),
  ]
  if rows.is_empty() {
    body.push(
      @views.text(
        tr(
          model.lang,
          "No recorded activity yet.",
          "尚无已记录的活动。",
        ),
        width=683.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.5, 400)).foreground(ui_dim()),
    )
  } else {
    for row_view in rows {
      body.push(row_view)
    }
  }
  @views.column([
    ui_divider_soft(),
    @views.padding_edges(
      @views.column(body, spacing=6.0, align=@style.CrossAlign::Start).frame(
        width=683.0,
      ),
      top=12.0,
      right=0.0,
      bottom=0.0,
      left=0.0,
    ),
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(width=683.0)
}

///|
fn workroom_thread(
  model : Model,
  chat : ChatIdentity?,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let entries : Array[@moui.View[Msg]] = []
  let updated = workroom_updated(model, chat)
  entries.push(
    @views.column([
      ui_mono(
        if updated == "" {
          tr(model.lang, "conversation", "对话记录")
        } else {
          compact_time(updated)
        },
        8.5,
      ),
      ui_divider_soft(),
    ], spacing=7.0, align=@style.CrossAlign::Start).frame(width=683.0),
  )
  let launch = model.agent.launch_prompt.trim().to_owned()
  if launch != "" {
    entries.push(workroom_user_entry(model, launch, ""))
  }
  for prompt in model.agent.sent_prompts {
    entries.push(workroom_user_entry(model, prompt, ""))
  }
  entries.push(workroom_assistant_entry(model, chat, bot))
  match workroom_pending_item(model) {
    Some(item) => entries.push(item)
    None => ()
  }
  entries.push(workroom_activity(model, chat))
  if chat is None && model.agent.session is None &&
    !model.composing_new_chat {
    entries.push(
      @views.column([
        @views.text(
          tr(model.lang, "Start a Chat", "开始一个对话"),
          align=@core.TextAlign::TextStart,
        ).font(ui_font(13.0, 600)).foreground(ui_text_color()),
        @views.text(
          tr(
            model.lang,
            "There is no Chat projection or Agent session yet. Start one below; this window will not invent a history.",
            "尚无对话投影或智能体会话。请在下方开始；此窗口不会编造历史。",
          ),
          width=683.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(11.0, 400)).foreground(ui_muted()),
        @views.row([
          ui_primary(tr(model.lang, "New Chat", "新对话"), NewChat),
          @views.spacer(weight=1.0),
        ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=683.0),
      ], spacing=8.0, align=@style.CrossAlign::Start).frame(width=683.0),
    )
  }
  @views.scroll_view(
    @views.padding_edges(
      @views.column(entries, spacing=18.0, align=@style.CrossAlign::Start).frame(
        width=683.0,
      ),
      top=18.0,
      right=28.0,
      bottom=12.0,
      left=28.0,
    ),
    width=739.0,
    height=444.0,
    request=@core.ScrollRequest::new(
      id=model.scroll_epoch + 101,
      offset=@core.Point::new(x=0.0, y=0.0),
    ),
    shows_indicator=true,
  )
}

///|
fn workroom_tool(icon : String, msg : Msg) -> @moui.View[Msg] {
  @views.container(
    @views.lucide_icon(icon, size=11.0, color=ui_dim()),
    width=19.0,
    height=19.0,
    corner_radius=3.0,
    border=Some(ui_edge(ui_border())),
    padding=0.0,
  ).on_tap(msg).cursor(@core.CursorStyle::Icon(@core.CursorIcon::CursorPointer))
}

///|
fn workroom_send_button() -> @moui.View[Msg] {
  @views.container(
    @views.lucide_icon("send", size=12.0, color=ui_on_ink(), stroke_width=2.0),
    width=22.0,
    height=22.0,
    background=ui_ink(),
    corner_radius=3.0,
    padding=0.0,
  ).on_tap(ComposerSend).cursor(
    @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
  )
}

///|
fn workroom_composer(
  model : Model,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let bot_items = workroom_bot_items(model)
  let workspace_name = workspace_context_name(model, model.agent.workspace_id)
  let meta : Array[@moui.View[Msg]] = [
    ui_select_field(
      tr(model.lang, "Reply", "回复"),
      bot_items,
      bot.id,
      model.composer_bot_picker_open,
      ComposerBotPicker(!model.composer_bot_picker_open),
      tr(model.lang, "Select a Bot", "选择 Bot"),
      170.0,
    ),
    ui_select_field(
      tr(model.lang, "Project", "项目"),
      workspace_menu_items(model, fn(value) { AgentWorkspaceSelect(value) }),
      model.agent.workspace_id,
      model.agent.workspace_picker_open,
      AgentWorkspaceToggle,
      tr(model.lang, "Select a workspace", "选择工作区"),
      210.0,
    ),
  ]
  if workspace_name != "" {
    meta.push(ui_meta(workspace_name))
  } else {
    meta.push(
      ui_meta(
        tr(
          model.lang,
          "No workspace selected; host default",
          "未选择工作区；使用主机默认目录",
        ),
      ),
    )
  }
  meta.push(@views.spacer(weight=1.0))
  let tools : Array[@moui.View[Msg]] = [
    workroom_tool("paperclip", SelectManageTab(ManageProjects)),
    workroom_tool("terminal", ProjectTerminalFocus),
    workroom_tool("list", SelectPage(Tasks)),
    @views.spacer(weight=1.0),
  ]
  if model.agent.session is Some(_) {
    tools.push(
      @views.container(
        @views.lucide_icon("square", size=10.0, color=ui_danger()),
        width=22.0,
        height=22.0,
        corner_radius=3.0,
        border=Some(ui_edge(ui_border())),
        padding=0.0,
      ).on_tap(AgentStopSession).cursor(
        @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
      ),
    )
  }
  tools.push(ui_mono(tr(model.lang, "↵ send", "↵ 发送"), 8.5))
  tools.push(workroom_send_button())
  @views.container(
    @views.padding_edges(
      @views.column([
        @views.row(meta, spacing=8.0, align=@style.CrossAlign::Center).frame(
          width=683.0,
        ),
        @views.text_area(
          model.agent.input,
          on_input=fn(value) { AgentInputDraft(value) },
          on_submit=Some(ComposerSend),
          placeholder=tr(
            model.lang,
            "Reply in this thread, assign work, or record progress…",
            "在这个线程里回复、分配工作，或记录进展…",
          ),
          lines=3,
          variant=@style.TextFieldVariant::Filled,
          theme=field_theme(),
          width=683.0,
          line_height=20.0,
        ),
        @views.row(tools, spacing=7.0, align=@style.CrossAlign::Center).frame(
          width=683.0,
        ),
      ], spacing=7.0, align=@style.CrossAlign::Start).frame(width=683.0),
      top=10.0,
      right=28.0,
      bottom=16.0,
      left=28.0,
    ),
    height=172.0,
    background=ui_surface_alt(),
    border=Some(ui_border_style(ui_border_soft(), 1.0)),
    padding=0.0,
  )
}

///|
fn detail_label(label : String) -> @moui.View[Msg] {
  @views.padding_edges(
    @views.text(label, align=@core.TextAlign::TextStart).font(
      ui_font(8.5, 650),
    ).foreground(ui_dim()),
    top=0.0,
    right=0.0,
    bottom=6.0,
    left=0.0,
  )
}

///|
fn detail_row(
  label : String,
  value : String,
  msg? : Msg,
) -> @moui.View[Msg] {
  let content = @views.row([
    @views.text(label, align=@core.TextAlign::TextStart).font(
      ui_font(9.5, 400),
    ).foreground(ui_dim()),
    @views.spacer(weight=1.0),
    @views.text(
      value,
      width=165.0,
      align=@core.TextAlign::TextEnd,
      wrap=false,
    ).font(ui_font(9.5, 520)).foreground(ui_text_color()),
  ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=258.0)
  let row_view = @views.container(
    @views.padding_xy(content, horizontal=0.0, vertical=2.0),
    height=21.0,
    padding=0.0,
  )
  match msg {
    Some(action) =>
      row_view.on_tap(action).cursor(
        @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
      )
    None => row_view
  }
}

///|
fn detail_member(
  name : String,
  role : String,
  dark : Bool,
  msg? : Msg,
) -> @moui.View[Msg] {
  let avatar = @views.container(
    @views.text(
      bot_initial(name),
      align=@core.TextAlign::TextCenter,
    ).font(ui_font(8.5, 600)).foreground(
      if dark { ui_on_ink() } else { ui_muted() },
    ),
    width=21.0,
    height=21.0,
    background=if dark { ui_ink() } else { ui_surface_alt() },
    corner_radius=10.0,
    border=Some(ui_edge(ui_border())),
    padding=0.0,
  )
  let content = @views.row([
    avatar,
    @views.column([
      @views.text(name, width=200.0, align=@core.TextAlign::TextStart, wrap=false).font(
        ui_font(9.5, 570),
      ).foreground(ui_text_color()),
      @views.text(role, width=200.0, align=@core.TextAlign::TextStart, wrap=false).font(
        ui_font(8.5, 400),
      ).foreground(ui_dim()),
    ], spacing=2.0, align=@style.CrossAlign::Start),
    @views.spacer(weight=1.0),
  ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=258.0)
  let row_view = @views.container(
    @views.padding_xy(content, horizontal=0.0, vertical=2.0),
    height=26.0,
    padding=0.0,
  )
  match msg {
    Some(action) =>
      row_view.on_tap(action).cursor(
        @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
      )
    None => row_view
  }
}

///|
fn workroom_pending_rows(model : Model) -> Array[@moui.View[Msg]] {
  let rows : Array[@moui.View[Msg]] = []
  let mut shown = 0
  for decision in model.inbox.decisions {
    if inbox_bucket_of(decision) != @contracts.INBOX_NEEDS_YOU {
      continue
    }
    if shown >= 2 {
      break
    }
    rows.push(
      @views.container(
        @views.padding_edges(
          @views.row([
            @views.container(@views.empty(), width=2.0, background=ui_warning(), padding=0.0),
            @views.padding_edges(
              @views.column([
                @views.text(
                  decision.title,
                  width=234.0,
                  align=@core.TextAlign::TextStart,
                  wrap=true,
                ).font(ui_font(9.5, 590)).foreground(ui_warning()),
                @views.text(
                  if decision.detail == "" {
                    decision.kind
                  } else {
                    decision.detail
                  },
                  width=234.0,
                  align=@core.TextAlign::TextStart,
                  wrap=true,
                ).font(ui_font(8.5, 400)).foreground(ui_muted()),
              ], spacing=3.0, align=@style.CrossAlign::Start).frame(width=234.0),
              top=7.0,
              right=8.0,
              bottom=7.0,
              left=8.0,
            ),
          ], spacing=0.0, align=@style.CrossAlign::Stretch),
        ),
        width=258.0,
        background=ui_surface(),
        corner_radius=3.0,
        border=Some(ui_edge(ui_border_soft())),
        padding=0.0,
      ).on_tap(SelectPage(Inbox)).cursor(
        @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
      ),
    )
    shown = shown + 1
  }
  rows
}

///|
fn workroom_files(model : Model) -> Array[@moui.View[Msg]] {
  let rows : Array[@moui.View[Msg]] = []
  match model.agent.session {
    Some(record) =>
      for artifact in record.artifacts {
        let name = artifact_basename(artifact)
        rows.push(
          @views.row([
            @views.lucide_icon("file", size=12.0, color=ui_dim()),
            @views.text(
              if name == "" { artifact } else { name },
              width=190.0,
              align=@core.TextAlign::TextStart,
              wrap=false,
            ).font(ui_font(9.5, 400)).foreground(ui_muted()),
            @views.spacer(weight=1.0),
            ui_mono(file_extension(name), 8.5),
          ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=258.0),
        )
      }
    None => ()
  }
  rows
}

///|
fn artifact_basename(value : String) -> String {
  let normalized = value.replace(old="\\", new="/")
  let parts = normalized.split("/")
  let mut last = ""
  for part in parts {
    if part != "" {
      last = part.to_owned()
    }
  }
  last
}

///|
fn file_extension(name : String) -> String {
  let parts = name.split(".")
  let mut extension = ""
  let mut seen_dot = false
  for raw in parts {
    let part = raw.to_owned()
    if seen_dot {
      extension = part
    } else {
      seen_dot = true
    }
  }
  extension
}

///|
fn workroom_id_row(
  label : String,
  value : String,
) -> @moui.View[Msg] {
  @views.row([
    @views.text(label, align=@core.TextAlign::TextStart).font(
      ui_font(8.5, 400),
    ).foreground(ui_dim()),
    @views.spacer(weight=1.0),
    ui_mono(short_metadata_id(value), 8.5),
    @views.container(
      @views.lucide_icon("copy", size=10.0, color=ui_dim()),
      width=18.0,
      height=18.0,
      corner_radius=3.0,
      padding=0.0,
    ).on_tap(CopyId(label, value)).cursor(
      @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
    ),
  ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=258.0)
}

///|
fn workroom_detail_rail(
  model : Model,
  chat : ChatIdentity?,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let status_rows : Array[@moui.View[Msg]] = [
    detail_label(tr(model.lang, "Status", "状态")),
    detail_row(
      tr(model.lang, "Current", "当前"),
      workroom_status(model),
    ),
    detail_row(
      tr(model.lang, "Updated", "最近更新"),
      match workroom_updated(model, chat) {
        "" => tr(model.lang, "not recorded", "未记录")
        value => value
      },
    ),
  ]
  let workspace_name = workspace_context_name(model, model.agent.workspace_id)
  let mut machine_name = tr(model.lang, "Local machine", "本地机器")
  match workspace_by_id(model.project.workspaces, model.agent.workspace_id) {
    Some(record) =>
      if record.machine_id != "" {
        machine_name = machine_name_for(model, record.machine_id)
      }
    None => ()
  }
  let executor = agent_name_for(model, model.agent.agent_id) +
    (if model.agent.mode == "" { "" } else { " · " + model.agent.mode })
  let session_id = match model.agent.session {
    Some(record) => record.id
    None => ""
  }
  let context_rows : Array[@moui.View[Msg]] = [
    detail_label(tr(model.lang, "Context", "上下文")),
    detail_row(
      tr(model.lang, "Project", "项目"),
      if workspace_name == "" {
        tr(model.lang, "not open", "未打开")
      } else {
        workspace_name
      },
      msg=SelectManageTab(ManageProjects),
    ),
    detail_row(
      tr(model.lang, "Workspace", "工作区"),
      if workspace_name == "" {
        tr(model.lang, "not open", "未打开")
      } else {
        workspace_name
      },
      msg=SelectManageTab(ManageProjects),
    ),
    detail_row(
      tr(model.lang, "Machine", "机器"),
      machine_name,
      msg=SelectManageTab(ManageMachines),
    ),
    detail_row(tr(model.lang, "Executor", "执行器"), executor),
    detail_row(
      tr(model.lang, "AgentSession", "智能体会话"),
      if session_id == "" {
        tr(model.lang, "none", "无")
      } else {
        short_metadata_id(session_id)
      },
    ),
  ]
  let pending = workroom_pending_rows(model)
  let pending_section : Array[@moui.View[Msg]] = [
    detail_label(tr(model.lang, "Needs you", "待你处理")),
  ]
  if pending.is_empty() {
    pending_section.push(
      @views.text(
        tr(model.lang, "No pending decisions.", "没有待处理决策。"),
        width=258.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.0, 400)).foreground(ui_dim()),
    )
  } else {
    for item in pending {
      pending_section.push(item)
    }
  }
  let files = workroom_files(model)
  let file_section : Array[@moui.View[Msg]] = [
    detail_label(tr(model.lang, "Files", "文件")),
  ]
  if files.is_empty() {
    file_section.push(
      @views.text(
        tr(model.lang, "No artifacts yet.", "尚无产物。"),
        width=258.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.0, 400)).foreground(ui_dim()),
    )
  } else {
    for item in files {
      file_section.push(item)
    }
  }
  let ids : Array[@moui.View[Msg]] = [
    detail_label(tr(model.lang, "IDs", "ID")),
  ]
  if session_id != "" {
    ids.push(workroom_id_row(tr(model.lang, "Session ID", "会话 ID"), session_id))
  }
  if bot.id != "" {
    ids.push(workroom_id_row(tr(model.lang, "Bot ID", "Bot ID"), bot.id))
  }
  match chat {
    Some(record) =>
      if !record.is_fallback && record.id != "" {
        ids.push(workroom_id_row(tr(model.lang, "Chat ID", "对话 ID"), record.id))
      }
    None => ()
  }
  let body = @views.column([
    @views.row([
      @views.text(tr(model.lang, "Details", "详情"), align=@core.TextAlign::TextStart).font(
        ui_font(13.0, 620),
      ).foreground(ui_text_color()),
      @views.spacer(weight=1.0),
      ui_mono(tr(model.lang, "context", "上下文"), 8.5),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=258.0),
    @views.column(status_rows, spacing=0.0, align=@style.CrossAlign::Start).frame(
      width=258.0,
    ),
    @views.container(
      @views.column([
        detail_label(tr(model.lang, "Participants", "参与者")),
        detail_member(
          bot.name,
          if bot.status == "" {
            tr(model.lang, "Bot identity", "Bot 身份")
          } else {
            bot.status
          },
          true,
          msg=OpenBotDetail(bot.id),
        ),
        detail_member(
          tr(model.lang, "Owner", "所有者"),
          tr(model.lang, "decisions · approval", "决策 · 审批"),
          false,
        ),
      ], spacing=0.0, align=@style.CrossAlign::Start).frame(width=258.0),
      border=Some(ui_border_style(ui_border_soft(), 1.0)),
      padding=0.0,
    ),
    @views.column(context_rows, spacing=0.0, align=@style.CrossAlign::Start).frame(
      width=258.0,
    ),
    @views.column(pending_section, spacing=6.0, align=@style.CrossAlign::Start).frame(
      width=258.0,
    ),
    @views.column(file_section, spacing=4.0, align=@style.CrossAlign::Start).frame(
      width=258.0,
    ),
    @views.column(ids, spacing=4.0, align=@style.CrossAlign::Start).frame(width=258.0),
    @views.text(
      tr(
        model.lang,
        "IDs are copyable metadata, not navigation.",
        "ID 仅作可复制元数据，不作为导航。",
      ),
      width=258.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(8.5, 400)).foreground(ui_dim()),
  ], spacing=12.0, align=@style.CrossAlign::Start).frame(width=258.0)
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        body,
        width=258.0,
        height=678.0,
        request=@core.ScrollRequest::new(
          id=model.scroll_epoch + 201,
          offset=@core.Point::new(x=0.0, y=0.0),
        ),
        shows_indicator=true,
      ),
      top=17.0,
      right=17.0,
      bottom=17.0,
      left=17.0,
    ),
    width=292.0,
    height=712.0,
    background=ui_rail(),
    padding=0.0,
  )
}

///|
fn workroom_page(model : Model) -> @moui.View[Msg] {
  let chat = active_chat_identity(model)
  let bot = active_bot_identity(model)
  let work_column = @views.column([
    workroom_header(model, chat, bot),
    workroom_thread(model, chat, bot),
    workroom_composer(model, bot),
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=739.0,
    height=712.0,
  )
  let rail = workroom_detail_rail(model, chat, bot)
  let split = @views.row([
    work_column,
    ui_vertical_rule(712.0),
    rail,
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=1032.0,
    height=712.0,
  )
  @views.container(
    split,
    width=1032.0,
    height=712.0,
    background=ui_paper(),
    padding=0.0,
  )
}
