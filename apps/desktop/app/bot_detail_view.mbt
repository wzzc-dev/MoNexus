///|
/// Bot identity and work ledger. It is a route inside the workroom, reached
/// from a Bot row or the Bot identity in the Chat header; it never becomes a
/// primary navigation entry. Tabs are quiet underlines, and work items use the
/// same hairline/row system as the workroom instead of rounded-card grids.

///|
fn bot_open_chat_msg(model : Model, bot : BotIdentity) -> Msg? {
  match latest_chat_for_bot(model.chats, bot.id) {
    Some(chat) => Some(SelectChat(chat.id))
    None =>
      if bot.is_fallback && model.agent.session is Some(_) {
        Some(SelectPage(Workroom))
      } else {
        None
      }
  }
}

///|
/// A Bot may only claim the window's transcript/artifacts when the current
/// Agent session is linked to one of its Chat projections (or when the Bot is
/// the honest fallback identity for that session).
fn bot_uses_current_session(model : Model, bot : BotIdentity) -> Bool {
  let session_id = match model.agent.session {
    Some(record) => record.id
    None => return false
  }
  if bot.is_fallback {
    return true
  }
  for chat in model.chats {
    if chat.bot_id == bot.id && chat.agent_session_id == session_id {
      return true
    }
  }
  false
}

///|
fn bot_files_for(model : Model, bot : BotIdentity) -> Array[@moui.View[Msg]] {
  if bot_uses_current_session(model, bot) {
    workroom_files(model)
  } else {
    []
  }
}

///|
fn bot_tab(
  model : Model,
  tab : BotTab,
  count : String,
) -> @moui.View[Msg] {
  let active = model.bot_tab == tab
  let label = tab.label_in(model.lang)
  let content = @views.row([
    @views.text(
      label,
      align=@core.TextAlign::TextStart,
    ).font(ui_font(10.5, if active { 620 } else { 400 })).foreground(
      if active { ui_ink() } else { ui_muted() },
    ),
    if count == "" {
      @views.empty()
    } else {
      @views.text(count, align=@core.TextAlign::TextStart).font(
        mono_font(8.5, 400),
      ).foreground(ui_dim())
    },
  ], spacing=5.0, align=@style.CrossAlign::Center).frame(width=80.0)
  @views.column([
    @views.padding_xy(content, horizontal=0.0, vertical=0.0),
    @views.container(
      @views.empty(),
      width=80.0,
      height=2.0,
      background=if active { ui_ink() } else { clear_color() },
      padding=0.0,
    ),
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=80.0,
    height=33.0,
  ).on_tap(SelectBotTab(tab)).cursor(
    @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
  )
}

///|
fn bot_chats_for(model : Model, bot : BotIdentity) -> Array[ChatIdentity] {
  let rows : Array[ChatIdentity] = []
  for record in model.chats {
    if record.bot_id == bot.id || (bot.is_fallback && record.bot_id == "") {
      rows.push(chat_identity_for(model, record))
    }
  }
  rows
}

///|
fn bot_task_visible(
  model : Model,
  task : @contracts.TaskRecord,
  bot : BotIdentity,
) -> Bool {
  if !bot.is_fallback {
    // Task records carry agent ids, not Bot ids. Without a typed Bot-to-Agent
    // mapping the page must not claim arbitrary tasks belong to this Bot.
    return false
  }
  task.agent_id == model.agent.agent_id || task.agent_id == bot.id
}

///|
fn bot_tasks_in_group(
  model : Model,
  bot : BotIdentity,
  group : BotWorkGroup,
) -> Array[@contracts.TaskRecord] {
  let rows : Array[@contracts.TaskRecord] = []
  for task in model.task.tasks {
    if bot_task_visible(model, task, bot) && task_group_of(task.status) == group {
      rows.push(task)
    }
  }
  rows
}

///|
fn bot_group_tone(group : BotWorkGroup) -> @core.Color {
  match group {
    BotWorkActive => ui_success()
    BotWorkWaiting => ui_warning()
    BotWorkPlanned => ui_dim()
    BotWorkClosed => ui_border()
  }
}

///|
fn bot_task_row(
  model : Model,
  task : @contracts.TaskRecord,
  group : BotWorkGroup,
) -> @moui.View[Msg] {
  let selected = model.bot_work_open == task.id
  let expanded = selected
  let row_content = @views.row([
    @views.container(
      @views.empty(),
      width=4.0,
      height=4.0,
      background=bot_group_tone(group),
      corner_radius=2.0,
      padding=0.0,
    ),
    @views.column([
      @views.text(
        "#" + short_metadata_id(task.id),
        align=@core.TextAlign::TextStart,
      ).font(mono_font(8.5, 400)).foreground(ui_dim()),
      @views.text(
        task.title,
        width=310.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.5, 560)).foreground(ui_text_color()),
      @views.text(
        if task.goal == "" {
          task.status
        } else {
          task.status + " · " + task.goal
        },
        width=310.0,
        align=@core.TextAlign::TextStart,
        wrap=false,
      ).font(ui_font(8.5, 400)).foreground(ui_dim()),
    ], spacing=2.0, align=@style.CrossAlign::Start).frame(width=310.0),
    @views.spacer(weight=1.0),
    @views.column([
      @views.text(
        workroom_clock(task.updated_at),
        align=@core.TextAlign::TextEnd,
      ).font(mono_font(8.5, 400)).foreground(ui_dim()),
      @views.container(
        @views.text(
          if expanded { "−" } else { "+" },
          align=@core.TextAlign::TextCenter,
        ).font(mono_font(10.5, 500)).foreground(ui_muted()),
        width=16.0,
        height=16.0,
        corner_radius=3.0,
        border=Some(ui_edge(ui_border_soft())),
        padding=0.0,
      ).on_tap(ToggleBotWorkItem(task.id)).cursor(
        @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
      ),
    ], spacing=5.0, align=@style.CrossAlign::Start),
  ], spacing=7.0, align=@style.CrossAlign::Start).frame(width=378.0)
  let row = @views.container(
    @views.padding_edges(
      row_content,
      top=7.0,
      right=7.0,
      bottom=7.0,
      left=8.0,
    ),
    width=402.0,
    background=if selected { ui_selected() } else { clear_color() },
    corner_radius=2.0,
    padding=0.0,
  ).on_tap(OpenBotWorkItem(task.id)).cursor(
    @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
  )
  let expanded_rows : Array[@moui.View[Msg]] = [row]
  if expanded {
    expanded_rows.push(
      @views.padding_edges(
        @views.column([
          @views.text(
            tr(model.lang, "Goal", "目标") + " · " + (
              if task.goal == "" {
                tr(model.lang, "not recorded", "未记录")
              } else {
                task.goal
              }
            ),
            width=386.0,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(9.0, 400)).foreground(ui_muted()),
          @views.text(
            tr(model.lang, "Verify", "完成标准") + " · " + (
              if task.verify.is_empty() {
                tr(model.lang, "not recorded", "未记录")
              } else {
                task.verify.join(" · ")
              }
            ),
            width=386.0,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(9.0, 400)).foreground(ui_dim()),
        ], spacing=4.0, align=@style.CrossAlign::Start).frame(width=386.0),
        top=0.0,
        right=8.0,
        bottom=7.0,
        left=8.0,
      ),
    )
  }
  @views.column(expanded_rows, spacing=0.0, align=@style.CrossAlign::Start)
}

///|
fn bot_group_section(
  model : Model,
  bot : BotIdentity,
  group : BotWorkGroup,
) -> Array[@moui.View[Msg]] {
  let tasks = bot_tasks_in_group(model, bot, group)
  let rows : Array[@moui.View[Msg]] = []
  if tasks.is_empty() {
    return rows
  }
  let limit = if model.bot_show_all { tasks.length() } else { 2 }
  rows.push(
    @views.padding_xy(
      @views.row([
        @views.text(
          group.label_in(model.lang),
          align=@core.TextAlign::TextStart,
        ).font(ui_font(9.5, 600)).foreground(ui_muted()),
        @views.text(
          tasks.length().to_string(),
          align=@core.TextAlign::TextStart,
        ).font(mono_font(8.5, 400)).foreground(ui_dim()),
        @views.spacer(weight=1.0),
      ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=390.0),
      horizontal=6.0,
      vertical=6.0,
    ),
  )
  let mut shown = 0
  for task in tasks {
    if shown >= limit {
      break
    }
    rows.push(bot_task_row(model, task, group))
    rows.push(ui_divider_soft())
    shown = shown + 1
  }
  rows
}

///|
fn bot_automation_rows(model : Model) -> Array[@moui.View[Msg]] {
  let rows : Array[@moui.View[Msg]] = []
  if model.automations.is_empty() {
    rows.push(
      @views.row([
        @views.lucide_icon("clock", size=12.0, color=ui_dim()),
        @views.text(
          tr(model.lang, "No automation projection yet.", "尚无自动化投影。"),
          width=300.0,
          align=@core.TextAlign::TextStart,
          wrap=false,
        ).font(ui_font(9.5, 400)).foreground(ui_dim()),
        @views.spacer(weight=1.0),
      ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=390.0),
    )
    rows.push(
      @views.text(
        tr(
          model.lang,
          "Automations will appear here once the Bot projection exposes them.",
          "Bot 投影提供自动化后，会在此显示。",
        ),
        width=390.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(8.5, 400)).foreground(ui_dim()),
    )
  } else {
    for automation in model.automations {
      rows.push(
        @views.row([
          @views.lucide_icon("refresh-cw", size=12.0, color=ui_dim()),
          @views.text(
            automation.title,
            width=260.0,
            align=@core.TextAlign::TextStart,
            wrap=false,
          ).font(ui_font(9.5, 560)).foreground(ui_text_color()),
          @views.spacer(weight=1.0),
          @views.text(
            automation.cadence,
            align=@core.TextAlign::TextEnd,
          ).font(mono_font(8.5, 400)).foreground(ui_dim()),
        ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=390.0),
      )
    }
  }
  rows
}

///|
fn bot_item_pane(
  model : Model,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let total = bot_tasks_in_group(model, bot, BotWorkActive).length() +
    bot_tasks_in_group(model, bot, BotWorkWaiting).length() +
    bot_tasks_in_group(model, bot, BotWorkPlanned).length() +
    bot_tasks_in_group(model, bot, BotWorkClosed).length()
  let content : Array[@moui.View[Msg]] = [
    @views.row([
      @views.text(
        tr(model.lang, "Work items", "工作事项"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(11.0, 620)).foreground(ui_text_color()),
      @views.text(
        total.to_string() + tr(model.lang, " items", " 项"),
        align=@core.TextAlign::TextStart,
      ).font(mono_font(8.5, 400)).foreground(ui_dim()),
      @views.spacer(weight=1.0),
      @views.text(
        tr(model.lang, "this Bot only", "只看当前 Bot"),
        align=@core.TextAlign::TextEnd,
      ).font(ui_font(8.5, 400)).foreground(ui_dim()),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=378.0),
  ]
  if total == 0 {
    content.push(
      @views.text(
        tr(
          model.lang,
          "No mapped work items yet. Task records carry agent ids; this Bot page will fill once a Bot-to-Task projection exists.",
          "尚无已映射的工作事项。任务记录只带智能体 ID；Bot 与任务的投影接入后，此页才会填入。",
        ),
        width=378.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.0, 400)).foreground(ui_dim()),
    )
  } else {
    let groups : Array[BotWorkGroup] = [
      BotWorkActive,
      BotWorkWaiting,
      BotWorkPlanned,
      BotWorkClosed,
    ]
    let mut hidden = 0
    for group in groups {
      let tasks = bot_tasks_in_group(model, bot, group)
      let before = content.length()
      for row in bot_group_section(model, bot, group) {
        content.push(row)
      }
      if content.length() > before && !model.bot_show_all {
        hidden = hidden + (tasks.length() - 2).max(0)
      }
    }
    if hidden > 0 {
      content.push(
        @views.padding_edges(
          @views.text(
            tr(model.lang, "Show ", "再显示 ") +
            hidden.to_string() +
            tr(model.lang, " more", " 项"),
            align=@core.TextAlign::TextStart,
          ).font(ui_font(9.0, 500)).foreground(ui_muted()),
          top=8.0,
          right=8.0,
          bottom=0.0,
          left=8.0,
        ).on_tap(ToggleBotShowAll).cursor(
          @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
        ),
      )
    }
  }
  content.push(ui_divider_soft())
  content.push(
    @views.padding_edges(
      @views.text(
        tr(model.lang, "Automations", "自动化"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(8.5, 650)).foreground(ui_dim()),
      top=10.0,
      right=8.0,
      bottom=6.0,
      left=8.0,
    ),
  )
  for row in bot_automation_rows(model) {
    content.push(row)
  }
  content.push(ui_divider_soft())
  content.push(
    @views.padding_edges(
      @views.text(
        tr(model.lang, "Projects", "项目"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(8.5, 650)).foreground(ui_dim()),
      top=10.0,
      right=8.0,
      bottom=6.0,
      left=8.0,
    ),
  )
  // A Chat projection carries a project id, not a workspace id. Do not join
  // those two id spaces; keep the Bot page honest until a typed project
  // projection exists.
  content.push(
    @views.text(
      tr(
        model.lang,
        "No project projection for this Bot yet.",
        "此 Bot 尚无项目投影。",
      ),
      width=390.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(8.5, 400)).foreground(ui_dim()),
  )
  content.push(
    @views.padding_edges(
      @views.row([
        ui_ghost_small(
          tr(model.lang, "Open Manage", "打开管理"),
          SelectManageTab(ManageProjects),
        ),
        @views.spacer(weight=1.0),
      ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=390.0),
      top=1.0,
      right=0.0,
      bottom=0.0,
      left=0.0,
    ),
  )
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        @views.column(content, spacing=6.0, align=@style.CrossAlign::Start).frame(
          width=402.0,
        ),
        width=402.0,
        height=569.0,
        request=@core.ScrollRequest::new(
          id=model.scroll_epoch + 300,
          offset=@core.Point::new(x=0.0, y=0.0),
        ),
        shows_indicator=true,
      ),
      top=12.0,
      right=14.0,
      bottom=16.0,
      left=14.0,
    ),
    width=430.0,
    height=597.0,
    background=ui_surface_alt(),
    padding=0.0,
  )
}

///|
fn bot_detail_empty(model : Model) -> @moui.View[Msg] {
  @views.column([
    @views.lucide_icon("list", size=20.0, color=ui_border()),
    @views.text(
      tr(model.lang, "Select a work item", "选择一个工作事项"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(13.0, 600)).foreground(ui_text_color()),
    @views.text(
      tr(
        model.lang,
        "Goal, completion criteria, Chat and activity appear here. Nothing is invented while the projection is empty.",
        "目标、完成标准、聊天与活动会在这里显示。投影为空时不会编造内容。",
      ),
      width=480.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(10.5, 400)).foreground(ui_muted()),
  ], spacing=8.0, align=@style.CrossAlign::Start)
}

///|
fn bot_task_events(
  model : Model,
  task : @contracts.TaskRecord,
) -> Array[@contracts.EventEnvelope] {
  let rows : Array[@contracts.EventEnvelope] = []
  for event in model.task.events {
    if event.subject.contains(task.id) {
      rows.push(event)
    }
  }
  rows
}

///|
fn bot_task_detail(
  model : Model,
  bot : BotIdentity,
  task : @contracts.TaskRecord,
) -> @moui.View[Msg] {
  let events = bot_task_events(model, task)
  let chat_mapped = bot_uses_current_session(model, bot) &&
    model.agent.session is Some(_) &&
    (task.agent_id == model.agent.agent_id || task.agent_id == bot.id)
  let sections : Array[@moui.View[Msg]] = [
    @views.row([
      @views.lucide_icon("arrow-right", size=11.0, color=ui_dim()),
      @views.text(
        tr(model.lang, "Home", "主页"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(9.0, 400)).foreground(ui_dim()),
    ], spacing=6.0, align=@style.CrossAlign::Center).on_tap(
      CloseBotWorkItem,
    ).cursor(@core.CursorStyle::Icon(@core.CursorIcon::CursorPointer)),
    @views.column([
      @views.row([
        @views.text(
          task.title,
          width=440.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(17.0, 640)).foreground(ui_text_color()),
        ui_tag(task.status),
        @views.spacer(weight=1.0),
      ], spacing=8.0, align=@style.CrossAlign::Start).frame(width=557.0),
      @views.row([
        @views.text(
          tr(model.lang, "Item ", "事项 ") + short_metadata_id(task.id),
          align=@core.TextAlign::TextStart,
        ).font(mono_font(8.5, 400)).foreground(ui_dim()),
        @views.text("·", align=@core.TextAlign::TextStart).font(
          ui_font(8.5, 400),
        ).foreground(ui_border()),
        @views.text(
          if bot.name == "" {
            tr(model.lang, "Bot", "Bot")
          } else {
            bot.name
          },
          align=@core.TextAlign::TextStart,
        ).font(ui_font(9.0, 400)).foreground(ui_dim()),
        @views.text("·", align=@core.TextAlign::TextStart).font(
          ui_font(8.5, 400),
        ).foreground(ui_border()),
        @views.text(
          compact_time(task.updated_at),
          align=@core.TextAlign::TextStart,
        ).font(mono_font(8.5, 400)).foreground(ui_dim()),
        @views.spacer(weight=1.0),
      ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=557.0),
    ], spacing=7.0, align=@style.CrossAlign::Start),
  ]
  sections.push(ui_divider_soft())
  sections.push(
    @views.text(
      tr(model.lang, "Goal", "目标"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(8.5, 650)).foreground(ui_dim()),
  )
  sections.push(
    @views.text(
      if task.goal == "" {
        tr(model.lang, "Not recorded yet.", "尚未记录。")
      } else {
        task.goal
      },
      width=557.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(10.5, 400)).foreground(ui_muted()),
  )
  sections.push(ui_divider_soft())
  sections.push(
    @views.text(
      tr(model.lang, "Completion criteria", "完成标准"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(8.5, 650)).foreground(ui_dim()),
  )
  if task.verify.is_empty() {
    sections.push(
      @views.text(
        tr(model.lang, "No criteria recorded.", "尚无完成标准。"),
        width=557.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_dim()),
    )
  } else {
    for criterion in task.verify {
      sections.push(
        @views.row([
          @views.container(
            @views.empty(),
            width=4.0,
            height=4.0,
            background=ui_border(),
            corner_radius=2.0,
            padding=0.0,
          ),
          @views.text(
            criterion,
            width=540.0,
            align=@core.TextAlign::TextStart,
            wrap=true,
          ).font(ui_font(9.5, 400)).foreground(ui_muted()),
        ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=557.0),
      )
    }
  }
  sections.push(ui_divider_soft())
  sections.push(
    @views.text(
      tr(model.lang, "Chat", "聊天"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(8.5, 650)).foreground(ui_dim()),
  )
  if chat_mapped {
    let launch = model.agent.launch_prompt.trim().to_owned()
    if launch != "" {
      sections.push(
        @views.row([
          @views.text(
            tr(model.lang, "Owner", "所有者"),
            align=@core.TextAlign::TextStart,
          ).font(ui_font(9.0, 600)).foreground(ui_text_color()),
          @views.spacer(weight=1.0),
          @views.text(
            compact_time(match model.agent.session {
              Some(record) => record.started_at
              None => ""
            }),
            align=@core.TextAlign::TextEnd,
          ).font(mono_font(8.0, 400)).foreground(ui_dim()),
        ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=557.0),
      )
      sections.push(
        @views.text(
          launch,
          width=557.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(9.5, 400)).foreground(ui_muted()),
      )
    }
    let transcript = model.agent.transcript.trim_end().to_owned()
    if transcript != "" {
      sections.push(
        @views.row([
          @views.text(
            bot.name,
            align=@core.TextAlign::TextStart,
          ).font(ui_font(9.0, 600)).foreground(ui_text_color()),
          @views.spacer(weight=1.0),
        ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=557.0),
      )
      sections.push(
        @views.text(
          transcript,
          width=557.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(9.5, 400)).foreground(ui_muted()),
      )
    }
  } else {
    sections.push(
      @views.text(
        tr(
          model.lang,
          "No Chat is mapped to this item yet.",
          "尚未有聊天映射到此事项。",
        ),
        width=557.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.5, 400)).foreground(ui_dim()),
    )
  }
  sections.push(
    @views.row([
      @views.text(
        tr(model.lang, "Open Chat", "打开对话") + " →",
        align=@core.TextAlign::TextStart,
      ).font(ui_font(8.5, 500)).foreground(ui_muted()),
      @views.spacer(weight=1.0),
    ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=557.0).on_tap(
      SelectPage(Workroom),
    ).cursor(@core.CursorStyle::Icon(@core.CursorIcon::CursorPointer)),
  )
  sections.push(ui_divider_soft())
  sections.push(
    @views.text(
      tr(model.lang, "Activity", "活动"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(8.5, 650)).foreground(ui_dim()),
  )
  if events.is_empty() {
    sections.push(
      @views.text(
        tr(model.lang, "No activity recorded.", "尚无活动记录。"),
        width=557.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.5, 400)).foreground(ui_dim()),
    )
  } else {
    let mut shown = 0
    for event in events {
      if shown >= 8 {
        break
      }
      sections.push(
        @views.row([
          @views.lucide_icon(
            if event.event_type.contains("failed") {
              "alert-triangle"
            } else {
              "check"
            },
            size=11.0,
            color=ui_dim(),
          ),
          @views.text(
            event.event_type,
            width=430.0,
            align=@core.TextAlign::TextStart,
            wrap=false,
          ).font(ui_font(9.0, 400)).foreground(ui_muted()),
          @views.spacer(weight=1.0),
          @views.text(
            workroom_clock(event.ts),
            align=@core.TextAlign::TextEnd,
          ).font(mono_font(8.0, 400)).foreground(ui_dim()),
        ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=557.0),
      )
      shown = shown + 1
    }
  }
  sections.push(ui_divider_soft())
  sections.push(
    @views.text(
      tr(model.lang, "Comment", "评论"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(8.5, 650)).foreground(ui_dim()),
  )
  sections.push(
    @views.text_area(
      model.bot_comment,
      on_input=fn(value) { BotCommentDraft(value) },
      placeholder=tr(model.lang, "Add a comment…", "添加评论…"),
      lines=2,
      variant=@style.TextFieldVariant::Filled,
      theme=field_theme(),
      width=557.0,
      line_height=18.0,
    ),
  )
  let count = model.bot_comment.to_array().length()
  sections.push(
    @views.row([
      @views.text(
        count.to_string() + "/50",
        align=@core.TextAlign::TextStart,
      ).font(mono_font(8.0, 400)).foreground(
        if count > 50 { ui_danger() } else { ui_dim() },
      ),
      @views.text(
        tr(model.lang, "Enter to send", "Enter 发送"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(8.0, 400)).foreground(ui_dim()),
      @views.spacer(weight=1.0),
      @views.container(
        @views.lucide_icon("send", size=11.0, color=ui_on_ink(), stroke_width=2.0),
        width=21.0,
        height=21.0,
        background=ui_ink(),
        corner_radius=3.0,
        padding=0.0,
      ).on_tap(BotCommentSave).cursor(
        @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
      ),
    ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=557.0),
  )
  if model.bot_comment_note != "" {
    sections.push(
      @views.text(
        model.bot_comment_note,
        width=557.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(8.5, 400)).foreground(
        if model.bot_comment_note.contains("not available") ||
          model.bot_comment_note.contains("尚未提供") {
          ui_warning()
        } else {
          ui_danger()
        },
      ),
    )
  }
  @views.column(sections, spacing=9.0, align=@style.CrossAlign::Start).frame(
    width=557.0,
  )
}

///|
fn bot_detail_pane(
  model : Model,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let mut selected : @contracts.TaskRecord? = None
  for task in model.task.tasks {
    if task.id == model.bot_work_open && bot_task_visible(model, task, bot) {
      selected = Some(task)
    }
  }
  let body = match selected {
    Some(task) => bot_task_detail(model, bot, task)
    None => bot_detail_empty(model)
  }
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        body,
        width=557.0,
        height=561.0,
        request=@core.ScrollRequest::new(
          id=model.scroll_epoch + 301,
          offset=@core.Point::new(x=0.0, y=0.0),
        ),
        shows_indicator=true,
      ),
      top=16.0,
      right=22.0,
      bottom=20.0,
      left=22.0,
    ),
    width=601.0,
    height=597.0,
    background=ui_canvas(),
    padding=0.0,
  )
}

///|
fn bot_home(model : Model, bot : BotIdentity) -> @moui.View[Msg] {
  let left = bot_item_pane(model, bot)
  let right = bot_detail_pane(model, bot)
  @views.row([
    left,
    ui_divider_soft(),
    right,
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=1032.0,
    height=597.0,
  )
}

///|
fn bot_chats_tab(
  model : Model,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let chats = bot_chats_for(model, bot)
  let rows : Array[@moui.View[Msg]] = [
    @views.row([
      @views.text(
        tr(model.lang, "Chats", "聊天"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(13.0, 620)).foreground(ui_text_color()),
      @views.spacer(weight=1.0),
      @views.text(
        chats.length().to_string(),
        align=@core.TextAlign::TextEnd,
      ).font(mono_font(9.0, 400)).foreground(ui_dim()),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=992.0),
  ]
  if chats.is_empty() {
    rows.push(
      @views.text(
        tr(
          model.lang,
          "No Chat projection for this Bot yet.",
          "此 Bot 尚无对话投影。",
        ),
        width=992.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(11.0, 400)).foreground(ui_dim()),
    )
    rows.push(
      @views.row([
        ui_primary(tr(model.lang, "New Chat", "新对话"), NewChat),
        @views.spacer(weight=1.0),
      ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=992.0),
    )
  } else {
    for chat in chats {
      rows.push(
        @views.container(
          @views.padding_edges(
            @views.row([
              @views.text(
                chat.title,
                width=600.0,
                align=@core.TextAlign::TextStart,
                wrap=false,
              ).font(ui_font(12.0, 560)).foreground(ui_text_color()),
              @views.text(
                bot_name_for_chat(
                  model,
                  chat,
                ),
                align=@core.TextAlign::TextStart,
              ).font(ui_font(9.5, 400)).foreground(ui_muted()),
              @views.spacer(weight=1.0),
              @views.text(
                compact_time(chat.updated_at),
                align=@core.TextAlign::TextEnd,
              ).font(mono_font(8.5, 400)).foreground(ui_dim()),
            ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=968.0),
            top=8.0,
            right=12.0,
            bottom=8.0,
            left=12.0,
          ),
          width=992.0,
          background=if chat.id == model.selected_chat {
            ui_selected()
          } else {
            clear_color()
          },
          corner_radius=3.0,
          padding=0.0,
        ).on_tap(SelectChat(chat.id)).cursor(
          @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
        ),
      )
      rows.push(ui_divider_soft())
    }
  }
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        @views.column(rows, spacing=10.0, align=@style.CrossAlign::Start).frame(
          width=992.0,
        ),
        width=992.0,
          height=565.0,
        request=@core.ScrollRequest::new(
          id=model.scroll_epoch + 302,
          offset=@core.Point::new(x=0.0, y=0.0),
        ),
        shows_indicator=true,
      ),
      top=16.0,
      right=20.0,
      bottom=16.0,
      left=20.0,
    ),
    width=1032.0,
    height=597.0,
    padding=0.0,
  )
}

///|
fn bot_agents_tab(model : Model) -> @moui.View[Msg] {
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        agents_page(model).frame(width=992.0),
        width=992.0,
        height=557.0,
        request=@core.ScrollRequest::new(
          id=model.scroll_epoch + 303,
          offset=@core.Point::new(x=0.0, y=0.0),
        ),
        shows_indicator=true,
      ),
      top=20.0,
      right=20.0,
      bottom=20.0,
      left=20.0,
    ),
    width=1032.0,
    height=597.0,
    padding=0.0,
  )
}

///|
fn bot_files_tab(
  model : Model,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  let files = bot_files_for(model, bot)
  let rows : Array[@moui.View[Msg]] = [
    @views.text(
      tr(model.lang, "Files", "文件"),
      align=@core.TextAlign::TextStart,
    ).font(ui_font(13.0, 620)).foreground(ui_text_color()),
  ]
  if files.is_empty() {
    rows.push(
      @views.text(
        tr(
          model.lang,
          "No artifacts mapped to this Bot yet.",
          "尚无映射到此 Bot 的产物。",
        ),
        width=992.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(11.0, 400)).foreground(ui_dim()),
    )
  } else {
    for file in files {
      rows.push(file)
      rows.push(ui_divider_soft())
    }
  }
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        @views.column(rows, spacing=10.0, align=@style.CrossAlign::Start).frame(
          width=992.0,
        ),
        width=992.0,
        height=565.0,
        request=@core.ScrollRequest::new(
          id=model.scroll_epoch + 304,
          offset=@core.Point::new(x=0.0, y=0.0),
        ),
        shows_indicator=true,
      ),
      top=16.0,
      right=20.0,
      bottom=16.0,
      left=20.0,
    ),
    width=1032.0,
    height=597.0,
    padding=0.0,
  )
}

///|
fn bot_detail_body(
  model : Model,
  bot : BotIdentity,
) -> @moui.View[Msg] {
  match model.bot_tab {
    BotHome => bot_home(model, bot)
    BotChats => bot_chats_tab(model, bot)
    BotAgents => bot_agents_tab(model)
    BotFiles => bot_files_tab(model, bot)
  }
}

///|
fn bot_detail_page(model : Model) -> @moui.View[Msg] {
  let bot = active_bot_identity(model)
  let chats = bot_chats_for(model, bot)
  let tasks = bot_tasks_in_group(model, bot, BotWorkActive).length() +
    bot_tasks_in_group(model, bot, BotWorkWaiting).length() +
    bot_tasks_in_group(model, bot, BotWorkPlanned).length() +
    bot_tasks_in_group(model, bot, BotWorkClosed).length()
  let header = @views.container(
    @views.padding_edges(
      @views.row([
        @views.container(
          @views.text(
            bot_initial(bot.name),
            align=@core.TextAlign::TextCenter,
          ).font(ui_font(15.0, 650)).foreground(ui_on_ink()),
          width=38.0,
          height=38.0,
          background=ui_ink(),
          corner_radius=19.0,
          padding=0.0,
        ),
        @views.column([
          @views.row([
            @views.text(
              bot.name,
              width=300.0,
              align=@core.TextAlign::TextStart,
              wrap=false,
            ).font(ui_font(21.0, 660)).foreground(ui_text_color()),
            ui_tag(
              if bot.status == "" {
                tr(model.lang, "idle", "空闲")
              } else {
                bot.status
              },
            ),
          ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=430.0),
          @views.text(
            bot.summary +
            " · " +
            chats.length().to_string() +
            tr(model.lang, " Chats", " 个 Chat"),
            width=430.0,
            align=@core.TextAlign::TextStart,
            wrap=false,
          ).font(ui_font(10.0, 400)).foreground(ui_muted()),
        ], spacing=4.0, align=@style.CrossAlign::Start),
        @views.spacer(weight=1.0),
        @views.row(
          {
            let actions : Array[@moui.View[Msg]] = []
            match bot_open_chat_msg(model, bot) {
              Some(msg) =>
                actions.push(
                  ui_ghost(
                    tr(model.lang, "Open current Chat", "打开当前 Chat"),
                    msg,
                  ),
                )
              None => ()
            }
            actions.push(ui_primary(tr(model.lang, "New Chat", "新对话"), NewChat))
            actions
          },
          spacing=6.0,
          align=@style.CrossAlign::Center,
        ),
      ], spacing=13.0, align=@style.CrossAlign::Center).frame(width=988.0),
      top=17.0,
      right=22.0,
      bottom=12.0,
      left=22.0,
    ),
    height=82.0,
    padding=0.0,
  )
  let tabs = @views.container(
    @views.padding_edges(
      @views.row([
        bot_tab(model, BotHome, tasks.to_string()),
        bot_tab(model, BotChats, chats.length().to_string()),
        bot_tab(model, BotAgents, ""),
        bot_tab(model, BotFiles, ""),
        @views.spacer(weight=1.0),
        @views.text(
          tr(
            model.lang,
            "Shared memory · not projected",
            "共享记忆 · 尚未投影",
          ),
          align=@core.TextAlign::TextEnd,
        ).font(ui_font(8.5, 400)).foreground(ui_dim()),
      ], spacing=20.0, align=@style.CrossAlign::Center).frame(width=988.0),
      top=0.0,
      right=22.0,
      bottom=0.0,
      left=22.0,
    ),
    height=33.0,
    border=Some(ui_border_style(ui_border_soft(), 1.0)),
    padding=0.0,
  )
  @views.container(
    @views.column([
      header,
      tabs,
      bot_detail_body(model, bot),
    ], spacing=0.0, align=@style.CrossAlign::Start).frame(
      width=1032.0,
      height=712.0,
    ),
    width=1032.0,
    height=712.0,
    background=ui_canvas(),
    padding=0.0,
  )
}
