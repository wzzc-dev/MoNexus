///|
/// Chat-first workroom. At the 1280 reference the main island is one 739pt work
/// column, a hairline, and a 292pt details rail; the work column takes the
/// remaining width on narrower windows. Projects, machines, executors and
/// sessions stay in the rail; they are context for this Chat, not peer
/// destinations.

///|
fn workroom_column_width() -> Double {
  (ui_main_width.val - 292.0 - 1.0).max(0.0)
}

///|
fn workroom_inner_width() -> Double {
  (workroom_column_width() - 56.0).max(0.0)
}

///|
fn workroom_message_width() -> Double {
  (workroom_inner_width() - 28.0).max(0.0)
}

///|
fn workroom_pending_width() -> Double {
  (workroom_inner_width() - 24.0).max(0.0)
}

///|
fn workroom_thread_height() -> Double {
  (ui_scroll_height.val - 95.0 - 1.0 - 172.0).max(0.0)
}

///|
fn workroom_rail_scroll_height() -> Double {
  (ui_scroll_height.val - 34.0).max(0.0)
}

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
  if model.selected_chat != "" && model.chat_session_state != "" {
    return model.chat_session_state
  }
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
fn chat_project_menu_items(
  model : Model,
  on_select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = [
    @views.MenuItem::new(
      id=PROJECT_FILTER_NONE,
      label=tr(model.lang, "No project", "无项目"),
      message=on_select(""),
    ),
  ]
  for record in model.project.projects {
    items.push(
      @views.MenuItem::new(
        id=record.id,
        label=project_name(record),
        message=on_select(record.id),
      ),
    )
  }
  items
}

///|
fn chat_bot_menu_items(
  model : Model,
  project_id : String,
  on_select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let records = if project_id == "" {
    model.bots
  } else {
    bots_in_project(model, project_id)
  }
  let items : Array[@views.MenuItem[Msg]] = []
  for record in records {
    items.push(
      @views.MenuItem::new(
        id=record.id,
        label=bot_name(record),
        message=on_select(record.id),
      ),
    )
  }
  items
}

///|
fn chat_agent_menu_items(
  model : Model,
  on_select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = []
  for record in model.bot_agents {
    if record.state == @contracts.AGENT_LIFECYCLE_SUSPENDED ||
      record.state == @contracts.AGENT_LIFECYCLE_RETIRED {
      continue
    }
    items.push(
      @views.MenuItem::new(
        id=record.id,
        label=record.name,
        message=on_select(record.id),
      ),
    )
  }
  items
}

///|
fn chat_workspace_menu_items(
  model : Model,
  on_select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = []
  for record in model.project.workspaces {
    items.push(
      @views.MenuItem::new(
        id=record.id,
        label=workspace_display_name(record),
        message=on_select(record.id),
      ),
    )
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
  let meta : Array[@moui.View[Msg]] = []
  if workspace_name != "" {
    meta.push(
      @views.text(workspace_name, align=@core.TextAlign::TextStart).font(
        ui_font(10.0, 400),
      ).foreground(ui_dim()),
    )
  }
  if updated != "" {
    if workspace_name != "" {
      meta.push(ui_meta("·"))
    }
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
        @views.text(
          ui_truncate(bot.name, 120.0, 10.0),
          width=120.0,
          align=@core.TextAlign::TextStart,
          wrap=false,
        ).font(
          ui_font(10.0, 550),
        ).foreground(ui_muted()),
      ], spacing=5.0, align=@style.CrossAlign::Center),
      horizontal=0.0,
    ),
    height=20.0,
    background=clear_color(),
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
            ui_truncate(title, 430.0, 18.0),
            align=@core.TextAlign::TextStart,
            wrap=false,
          ).font(ui_font(18.0, 650)).foreground(ui_text_color()),
          ui_tag(workroom_status(model)),
          @views.spacer(weight=1.0),
          bot_chip,
        ], spacing=9.0, align=@style.CrossAlign::Center).frame(
          width=workroom_inner_width(),
        ),
        @views.row(meta, spacing=6.0, align=@style.CrossAlign::Center).frame(
          width=workroom_inner_width(),
        ),
      ], spacing=7.0, align=@style.CrossAlign::Start).frame(
        width=workroom_inner_width(),
      ),
      top=22.0,
      right=28.0,
      bottom=16.0,
      left=28.0,
    ),
    height=95.0,
    background=clear_color(),
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
    width=workroom_message_width(),
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
        ], spacing=7.0, align=@style.CrossAlign::Center).frame(
          width=workroom_message_width(),
        ),
        body,
      ], spacing=7.0, align=@style.CrossAlign::Start).frame(
        width=workroom_message_width(),
      ),
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
  ], spacing=0.0, align=@style.CrossAlign::Stretch).frame(
    width=workroom_inner_width(),
  )
}

///|
fn workroom_assistant_entry(
  model : Model,
  chat : ChatIdentity?,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let transcript = model.agent.transcript.trim_end().to_owned()
  let when = match chat {
    Some(record) => workroom_clock(record.updated_at)
    None => ""
  }
  workroom_assistant_body_entry(
    model,
    bot.name,
    if transcript == "" {
      tr(
        model.lang,
        "No reply yet. Replies appear here as continuous text.",
        "尚无回复。回复会在这里以连续正文显示。",
      )
    } else {
      transcript
    },
    when,
    transcript == "",
  )
}

///|
fn workroom_assistant_body_entry(
  model : Model,
  name : String,
  body_text : String,
  when : String,
  empty : Bool,
) -> @moui.View[Msg] {
  let body = if empty {
    @views.text(
      body_text,
      width=workroom_inner_width(),
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(12.0, 400)).foreground(ui_dim())
  } else {
    @views.text(
      body_text,
      width=workroom_inner_width(),
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(13.0, 400)).foreground(ui_text_color())
  }
  @views.column([
    @views.row([
      @views.text(name, align=@core.TextAlign::TextStart).font(
        ui_font(11.0, 620),
      ).foreground(ui_text_color()),
      @views.text(
        tr(model.lang, "agent", "智能体"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(9.5, 400)).foreground(ui_dim()),
      @views.spacer(weight=1.0),
      if when == "" { ui_meta("") } else { ui_mono(when, 8.5) },
    ], spacing=7.0, align=@style.CrossAlign::Center).frame(
      width=workroom_inner_width(),
    ),
    body,
  ], spacing=7.0, align=@style.CrossAlign::Start).frame(
    width=workroom_inner_width(),
  )
}

///|
/// `chat.read` streams the runtime transcript. The host also projects
/// assistant-visible ACP chunks into `chat.messages`, so rendering both raw
/// surfaces would duplicate the reply. Strip already-projected assistant
/// bodies from the tail and only paint genuinely unprojected runtime text.
fn chat_live_tail(model : Model) -> String {
  let mut tail = model.chat_live_text
  if tail == "" {
    return ""
  }
  let assistant_bodies : Array[String] = []
  for message in model.chat_messages {
    if message.role == @contracts.CHAT_MESSAGE_ROLE_ASSISTANT &&
      message.body != "" {
      assistant_bodies.push(message.body)
    }
  }
  let mut index = assistant_bodies.length()
  while index > 0 {
    let body = assistant_bodies[index - 1]
    if tail.has_suffix(body) {
      tail = tail[:tail.length() - body.length()].to_owned()
    }
    index = index - 1
  }
  tail.trim_end().to_owned()
}

///|
fn workroom_chat_message_entry(
  model : Model,
  message : @contracts.ChatMessage,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let when = workroom_clock(message.created_at)
  if message.role == @contracts.CHAT_MESSAGE_ROLE_USER {
    workroom_user_entry(model, message.body, when)
  } else if message.role == @contracts.CHAT_MESSAGE_ROLE_ASSISTANT {
    workroom_assistant_body_entry(
      model,
      bot.name,
      message.body,
      when,
      false,
    )
  } else {
    @views.column([
      @views.row([
        @views.text(
          tr(model.lang, "System", "系统"),
          align=@core.TextAlign::TextStart,
        ).font(ui_font(9.5, 570)).foreground(ui_dim()),
        @views.spacer(weight=1.0),
        if when == "" { ui_meta("") } else { ui_mono(when, 8.5) },
      ], spacing=7.0, align=@style.CrossAlign::Center).frame(
        width=workroom_inner_width(),
      ),
      @views.text(
        message.body,
        width=workroom_inner_width(),
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_muted()),
    ], spacing=5.0, align=@style.CrossAlign::Start).frame(
      width=workroom_inner_width(),
    )
  }
}

///|
fn chat_pending_label(model : Model) -> String {
  for record in model.inbox.decisions {
    if record.id == model.chat_pending_decision {
      if record.title != "" {
        return record.title
      }
      if record.kind != "" {
        return record.kind
      }
    }
  }
  tr(
    model.lang,
    "Owner Decision required. Open Inbox to review.",
    "需要所有者决策。请打开收件箱查看。",
  )
}

///|
fn workroom_pending_item(model : Model) -> @moui.View[Msg]? {
  if model.chat_pending_decision == "" {
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
              ], spacing=7.0, align=@style.CrossAlign::Center).frame(
                width=workroom_pending_width(),
              ),
              @views.text(
                chat_pending_label(model),
                width=workroom_pending_width(),
                align=@core.TextAlign::TextStart,
                wrap=true,
              ).font(ui_font(10.0, 400)).foreground(ui_muted()),
              @views.row([
                ui_ghost_small(
                  tr(model.lang, "Open Inbox", "打开收件箱"),
                  SelectPage(Inbox),
                ),
                @views.spacer(weight=1.0),
              ], spacing=6.0, align=@style.CrossAlign::Center).frame(
                width=workroom_pending_width(),
              ),
            ], spacing=7.0, align=@style.CrossAlign::Start).frame(
              width=workroom_pending_width(),
            ),
            top=10.0,
            right=11.0,
            bottom=10.0,
            left=11.0,
          ),
        ], spacing=0.0, align=@style.CrossAlign::Stretch),
      ),
      width=workroom_inner_width(),
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
  @views.container(
    @views.row([
      @views.lucide_icon(icon, size=12.0, color=ui_dim()),
      @views.text(label, align=@core.TextAlign::TextStart).font(
        ui_font(9.5, 400),
      ).foreground(ui_muted()),
      @views.spacer(weight=1.0),
      if when == "" { ui_meta("") } else { ui_mono(when, 8.5) },
    ], spacing=7.0, align=@style.CrossAlign::Center).frame(
      width=workroom_inner_width(),
    ),
    height=27.0,
    background=clear_color(),
    padding=0.0,
  )
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
    @views.container(
      @views.row([
        @views.lucide_icon("list", size=12.0, color=ui_dim()),
        @views.text(tr(model.lang, "Activity", "活动"), align=@core.TextAlign::TextStart).font(
          ui_font(9.5, 570),
        ).foreground(ui_muted()),
        @views.spacer(weight=1.0),
        ui_mono(tr(model.lang, "this session", "当前会话"), 8.5),
      ], spacing=7.0, align=@style.CrossAlign::Center).frame(
        width=workroom_inner_width(),
      ),
      height=31.0,
      background=clear_color(),
      padding=0.0,
    ),
  ]
  if rows.is_empty() {
    body.push(
      @views.padding_edges(
        @views.text(
          tr(
            model.lang,
            "No recorded activity yet.",
            "尚无已记录的活动。",
          ),
          width=workroom_inner_width(),
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(9.5, 400)).foreground(ui_dim()),
        top=5.0,
      ),
    )
  } else {
    let mut index = 0
    for row_view in rows {
      if index > 0 {
        body.push(ui_divider_soft())
      }
      body.push(row_view)
      index = index + 1
    }
  }
  @views.column([
    ui_divider_soft(),
    @views.padding_edges(
      @views.column(body, spacing=0.0, align=@style.CrossAlign::Start).frame(
        width=workroom_inner_width(),
      ),
      top=12.0,
      right=0.0,
      bottom=0.0,
      left=0.0,
    ),
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=workroom_inner_width(),
  )
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
    ], spacing=7.0, align=@style.CrossAlign::Start).frame(
      width=workroom_inner_width(),
    ),
  )
  let has_chat = match chat {
    Some(record) => !record.is_fallback
    None => false
  }
  if has_chat {
      if model.chat_messages.is_empty() {
        entries.push(
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
            width=workroom_inner_width(),
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(12.0, 400)).foreground(ui_dim()),
        )
      } else {
        for message in model.chat_messages {
          entries.push(workroom_chat_message_entry(model, message, bot))
        }
      }
      if model.chat_messages_in_flight && !model.chat_messages.is_empty() {
        entries.push(ui_meta(tr(model.lang, "Loading more messages...", "正在加载更多消息...")))
      }
      let live = chat_live_tail(model)
      if live != "" {
        entries.push(
          workroom_assistant_body_entry(
            model,
            bot.name,
            live,
            "",
            false,
          ),
        )
      }
      if !chat_session_active(model.chat_session_state) {
        entries.push(
          @views.column([
            @views.text(
              tr(
                model.lang,
                "This Chat has no running Agent session.",
                "此对话没有运行中的智能体会话。",
              ),
              width=workroom_inner_width(),
              align=@core.TextAlign::TextStart,
              wrap=true,
            ).font(ui_font(10.0, 400)).foreground(ui_muted()),
            @views.row([
              ui_ghost_small(
                tr(model.lang, "Start Agent session", "启动智能体会话"),
                ChatStartSession,
              ),
              @views.spacer(weight=1.0),
            ], spacing=8.0, align=@style.CrossAlign::Center).frame(
              width=workroom_inner_width(),
            ),
          ], spacing=6.0, align=@style.CrossAlign::Start).frame(
            width=workroom_inner_width(),
          ),
        )
      }
  } else {
    let launch = model.agent.launch_prompt.trim().to_owned()
    if launch != "" {
      entries.push(workroom_user_entry(model, launch, ""))
    }
    for prompt in model.agent.sent_prompts {
      entries.push(workroom_user_entry(model, prompt, ""))
    }
    entries.push(workroom_assistant_entry(model, chat, bot))
  }
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
          width=workroom_inner_width(),
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(11.0, 400)).foreground(ui_muted()),
        @views.row([
          ui_primary(tr(model.lang, "New Chat", "新对话"), NewChat),
          @views.spacer(weight=1.0),
        ], spacing=8.0, align=@style.CrossAlign::Center).frame(
          width=workroom_inner_width(),
        ),
      ], spacing=8.0, align=@style.CrossAlign::Start).frame(
        width=workroom_inner_width(),
      ),
    )
  }
  @views.scroll_view(
    @views.padding_edges(
      @views.column(entries, spacing=18.0, align=@style.CrossAlign::Start).frame(
        width=workroom_inner_width(),
      ),
      top=18.0,
      right=28.0,
      bottom=12.0,
      left=28.0,
    ),
    width=workroom_column_width(),
    height=workroom_thread_height(),
    request=@core.ScrollRequest::new(
      id=model.scroll_epoch + 101,
      offset=@core.Point::new(x=0.0, y=0.0),
    ),
    shows_indicator=true,
  )
}

///|
fn workroom_new_chat_footer(model : Model) -> @moui.View[Msg] {
  let draft = model.chat_draft
  let message = if draft.message != "" {
    ui_muted_wrapped(draft.message, workroom_inner_width())
  } else if model.chat_error != "" {
    @views.text(
      model.chat_error,
      width=workroom_inner_width(),
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(10.0, 400)).foreground(ui_danger())
  } else {
    ui_meta(
      tr(
        model.lang,
        "The Chat is created on the host, then its first AgentSession starts in the selected workspace.",
        "对话会先在主机上创建，然后在所选工作区启动首个智能体会话。",
      ),
    )
  }
  @views.container(
    @views.padding_edges(
      @views.column([
        @views.row([
          ui_primary(
            if draft.busy {
              tr(model.lang, "Creating...", "正在创建...")
            } else {
              tr(model.lang, "Create Chat", "创建对话")
            },
            ChatCreateSubmit,
          ),
          ui_ghost(tr(model.lang, "Cancel", "取消"), CancelNewChat),
          @views.spacer(weight=1.0),
          ui_mono(tr(model.lang, "host RPC", "主机 RPC"), 8.5),
        ], spacing=8.0, align=@style.CrossAlign::Center).frame(
          width=workroom_inner_width(),
        ),
        message,
      ], spacing=8.0, align=@style.CrossAlign::Start).frame(
        width=workroom_inner_width(),
      ),
      top=12.0,
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
fn workroom_new_chat_form(model : Model) -> @moui.View[Msg] {
  let draft = model.chat_draft
  let project_id = draft.project_id
  let bot_items = chat_bot_menu_items(model, project_id, fn(value) {
    ChatDraftBot(value)
  })
  let project_items = chat_project_menu_items(model, fn(value) {
    ChatDraftProject(value)
  })
  let workspace_items = chat_workspace_menu_items(model, fn(value) {
    ChatDraftWorkspace(value)
  })
  let agent_items = chat_agent_menu_items(model, fn(value) {
    ChatDraftAgent(value)
  })
  let fields : Array[@moui.View[Msg]] = [
    ui_field(
      tr(model.lang, "Chat title", "对话标题"),
      draft.title,
      fn(value) { ChatDraftTitle(value) },
      tr(model.lang, "Optional; defaults to the Bot name", "可选；默认为 Bot 名称"),
      483.0,
    ),
    @views.row([
      ui_select_field(
        tr(model.lang, "Bot", "Bot"),
        bot_items,
        draft.bot_id,
        draft.bot_picker_open,
        ChatDraftPicker(ChatPickerBot),
        if model.bots_loaded {
          tr(model.lang, "Select a Bot", "选择 Bot")
        } else {
          tr(model.lang, "Loading Bots...", "正在加载 Bot...")
        },
        236.0,
      ),
      ui_select_field(
        tr(model.lang, "Project", "项目"),
        project_items,
        draft.project_id,
        draft.project_picker_open,
        ChatDraftPicker(ChatPickerProject),
        tr(model.lang, "No project", "无项目"),
        236.0,
      ),
    ], spacing=11.0, align=@style.CrossAlign::Center).frame(width=483.0),
    @views.row([
      ui_select_field(
        tr(model.lang, "Workspace", "工作区"),
        workspace_items,
        draft.workspace_id,
        draft.workspace_picker_open,
        ChatDraftPicker(ChatPickerWorkspace),
        if model.project.workspaces_loaded {
          tr(model.lang, "Select an open workspace", "选择已打开的工作区")
        } else {
          tr(model.lang, "Loading workspaces...", "正在加载工作区...")
        },
        320.0,
      ),
      ui_select_field(
        tr(model.lang, "Agent", "智能体"),
        agent_items,
        draft.agent_id,
        draft.agent_picker_open,
        ChatDraftPicker(ChatPickerAgent),
        if model.bot_agents_loaded {
          tr(model.lang, "Select an Agent", "选择智能体")
        } else {
          tr(model.lang, "Loading Agents...", "正在加载智能体...")
        },
        152.0,
      ),
    ], spacing=11.0, align=@style.CrossAlign::Center).frame(width=483.0),
  ]
  if project_id != "" && bot_items.is_empty() {
    let message = if !model.project_memberships_loaded {
      tr(
        model.lang,
        "Loading Project membership from the host...",
        "正在从主机加载项目成员...",
      )
    } else {
      tr(
        model.lang,
        "This Project has no Bot members yet. Add a Bot from the Project page, then choose it here.",
        "此项目尚无 Bot 成员。请先在项目页添加 Bot，再在此选择。",
      )
    }
    fields.push(
      @views.text(
        message,
        width=workroom_inner_width(),
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_warning()),
    )
  }
  fields.push(
    @views.text(
      tr(
        model.lang,
        "Bot, Project, Workspace and Agent are selected by name. No bot_/cht_/asn_/ws_ id needs to be typed.",
        "Bot、项目、工作区和智能体均按名称选择，无需输入 bot_/cht_/asn_/ws_ 原始 ID。",
      ),
      width=workroom_inner_width(),
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(9.5, 400)).foreground(ui_dim()),
  )
  @views.scroll_view(
    @views.padding_edges(
      @views.column(fields, spacing=15.0, align=@style.CrossAlign::Start).frame(
        width=workroom_inner_width(),
      ),
      top=18.0,
      right=28.0,
      bottom=12.0,
      left=28.0,
    ),
    width=workroom_column_width(),
    height=workroom_thread_height(),
    request=@core.ScrollRequest::new(
      id=model.scroll_epoch + 102,
      offset=@core.Point::new(x=0.0, y=0.0),
    ),
    shows_indicator=true,
  )
}

///|
fn workroom_new_chat_page(model : Model) -> @moui.View[Msg] {
  let bot = active_bot_identity(model)
  @views.column([
    workroom_header(model, None, bot),
    ui_divider_soft(),
    workroom_new_chat_form(model),
    workroom_new_chat_footer(model),
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=workroom_column_width(),
    height=ui_scroll_height.val,
  )
}

///|
fn workroom_tool(icon : String, msg : Msg) -> @moui.View[Msg] {
  @views.container(
    @views.lucide_icon(icon, size=11.0, color=ui_dim()),
    width=19.0,
    height=19.0,
    background=clear_color(),
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
  if model.selected_chat != "" &&
    !chat_session_active(model.chat_session_state) {
    tools.push(
      ui_ghost_small(
        tr(model.lang, "Start session", "启动会话"),
        ChatStartSession,
      ),
    )
  }
  if model.selected_chat == "" && model.agent.session is Some(_) {
    tools.push(
      @views.container(
        @views.lucide_icon("square", size=10.0, color=ui_danger()),
        width=22.0,
        height=22.0,
        background=clear_color(),
        corner_radius=3.0,
        border=Some(ui_edge(ui_border())),
        padding=0.0,
      ).on_tap(AgentStopSession).cursor(
        @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
      ),
    )
  } else if chat_session_active(model.chat_session_state) {
    tools.push(
      @views.container(
        @views.lucide_icon("square", size=10.0, color=ui_danger()),
        width=22.0,
        height=22.0,
        background=clear_color(),
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
  let feedback : Array[@moui.View[Msg]] = []
  if model.chat_error != "" {
    feedback.push(
      @views.text(
        model.chat_error,
        width=workroom_inner_width(),
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.5, 400)).foreground(ui_danger()),
    )
  } else if model.chat_notice != "" {
    feedback.push(ui_meta(model.chat_notice))
  }
  @views.container(
    @views.padding_edges(
      @views.column([
        @views.row(meta, spacing=8.0, align=@style.CrossAlign::Center).frame(
          width=workroom_inner_width(),
        ),
        @views.column(feedback, spacing=3.0, align=@style.CrossAlign::Start),
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
          width=workroom_inner_width(),
          line_height=20.0,
        ),
        @views.row(tools, spacing=7.0, align=@style.CrossAlign::Center).frame(
          width=workroom_inner_width(),
        ),
      ], spacing=7.0, align=@style.CrossAlign::Start).frame(
        width=workroom_inner_width(),
      ),
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
    bottom=8.0,
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
      ui_truncate(value, 165.0, 9.5),
      width=165.0,
      align=@core.TextAlign::TextEnd,
      wrap=false,
    ).font(ui_font(9.5, 520)).foreground(ui_text_color()),
  ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=258.0)
  let row_view = @views.container(
    @views.padding_xy(content, horizontal=0.0, vertical=2.0),
    height=21.0,
    background=clear_color(),
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
    background=clear_color(),
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
          @views.container(
            @views.row([
              @views.lucide_icon("file", size=12.0, color=ui_dim()),
              @views.text(
                ui_truncate(
                  if name == "" { artifact } else { name },
                  190.0,
                  9.5,
                ),
                width=190.0,
                align=@core.TextAlign::TextStart,
                wrap=false,
              ).font(ui_font(9.5, 400)).foreground(ui_muted()),
              @views.spacer(weight=1.0),
              ui_mono(file_extension(name), 8.5),
            ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=258.0),
            height=25.0,
            background=clear_color(),
            padding=0.0,
          ),
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
  let executor = match chat {
    Some(record) =>
      if record.is_fallback || record.agent_name == "" {
        agent_name_for(model, model.agent.agent_id) +
        (if model.agent.mode == "" { "" } else { " · " + model.agent.mode })
      } else {
        record.agent_name +
        (if record.software_id == "" {
          ""
        } else {
          " · " + record.software_id
        })
      }
    None =>
      agent_name_for(model, model.agent.agent_id) +
      (if model.agent.mode == "" { "" } else { " · " + model.agent.mode })
  }
  let session_id = match model.agent.session {
    Some(record) => record.id
    None => ""
  }
  let chat_project = match chat {
    Some(record) =>
      if record.is_fallback {
        tr(model.lang, "not recorded", "未记录")
      } else {
        chat_project_label(model, record.project_id)
      }
    None => tr(model.lang, "not recorded", "未记录")
  }
  let context_rows : Array[@moui.View[Msg]] = [
    detail_label(tr(model.lang, "Context", "上下文")),
    detail_row(
      tr(model.lang, "Project", "项目"),
      chat_project,
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
      if model.chat_session_state != "" {
        model.chat_session_state
      } else if session_id == "" {
        tr(model.lang, "none", "无")
      } else {
        tr(model.lang, "recorded", "已记录")
      },
    ),
  ]
  if model.chat_pending_decision != "" {
    context_rows.push(
      detail_row(
        tr(model.lang, "Pending", "待处理"),
        tr(model.lang, "decision in this Chat", "此对话中的决策"),
        msg=SelectPage(Inbox),
      ),
    )
  }
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
  let heading = @views.padding_edges(
    @views.row([
      @views.text(tr(model.lang, "Details", "详情"), align=@core.TextAlign::TextStart).font(
        ui_font(13.0, 620),
      ).foreground(ui_text_color()),
      @views.spacer(weight=1.0),
      ui_mono(tr(model.lang, "context", "上下文"), 8.5),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=258.0),
    bottom=11.0,
  )
  let participants_section = @views.column([
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
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(width=258.0)
  let body = @views.column([
    heading,
    ui_divider_soft(),
    @views.padding_edges(
      @views.column(status_rows, spacing=0.0, align=@style.CrossAlign::Start).frame(
        width=258.0,
      ),
      top=11.0,
      bottom=11.0,
    ),
    ui_divider_soft(),
    @views.padding_edges(
      participants_section,
      top=11.0,
      bottom=11.0,
    ),
    ui_divider_soft(),
    @views.padding_edges(
      @views.column(context_rows, spacing=0.0, align=@style.CrossAlign::Start).frame(
        width=258.0,
      ),
      top=11.0,
      bottom=11.0,
    ),
    ui_divider_soft(),
    @views.padding_edges(
      @views.column(pending_section, spacing=6.0, align=@style.CrossAlign::Start).frame(
        width=258.0,
      ),
      top=11.0,
      bottom=11.0,
    ),
    ui_divider_soft(),
    @views.padding_edges(
      @views.column(file_section, spacing=4.0, align=@style.CrossAlign::Start).frame(
        width=258.0,
      ),
      top=11.0,
      bottom=11.0,
    ),
    ui_divider_soft(),
    @views.padding_edges(
      @views.text(
        tr(
          model.lang,
          "This surface addresses Bots and Chats by name; route ids stay in window metadata.",
          "此界面按名称定位 Bot 与对话；路由 ID 仅保留在窗口元数据中。",
        ),
        width=258.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(8.5, 400)).foreground(ui_dim()),
      top=11.0,
      bottom=0.0,
    ),
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(width=258.0)
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        body,
        width=258.0,
        height=workroom_rail_scroll_height(),
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
    height=ui_scroll_height.val,
    background=ui_rail(),
    padding=0.0,
  )
}

///|
fn workroom_page(model : Model) -> @moui.View[Msg] {
  let chat = active_chat_identity(model)
  let bot = active_bot_identity(model)
  let work_column = if model.composing_new_chat {
    workroom_new_chat_page(model)
  } else {
    @views.column([
      workroom_header(model, chat, bot),
      ui_divider_soft(),
      workroom_thread(model, chat, bot),
      workroom_composer(model, bot),
    ], spacing=0.0, align=@style.CrossAlign::Start).frame(
      width=workroom_column_width(),
      height=ui_scroll_height.val,
    )
  }
  let rail = workroom_detail_rail(model, chat, bot)
  let split = @views.row([
    work_column,
    ui_vertical_rule(ui_scroll_height.val),
    rail,
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=ui_main_width.val,
    height=ui_scroll_height.val,
  )
  @views.container(
    split,
    width=ui_main_width.val,
    height=ui_scroll_height.val,
    background=ui_paper(),
    padding=0.0,
  )
}
