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
  let count_width = if count == "" { 0.0 } else { 5.0 + ui_advance(count, 8.5) }
  let tab_width = ui_advance(label, 10.5) + count_width + 1.0
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
  ], spacing=5.0, align=@style.CrossAlign::Center).frame(width=tab_width)
  @views.column([
    @views.padding_xy(content, horizontal=0.0, vertical=0.0),
    @views.container(
      @views.empty(),
      width=tab_width,
      height=2.0,
      background=if active { ui_ink() } else { clear_color() },
      padding=0.0,
    ),
  ], spacing=0.0, align=@style.CrossAlign::Start).frame(
    width=tab_width,
    height=32.0,
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
fn bot_project_filter_menu_items(
  model : Model,
  on_select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = [
    @views.MenuItem::new(
      id="",
      label=project_filter_label(model, ""),
      message=on_select(""),
    ),
    @views.MenuItem::new(
      id=PROJECT_FILTER_NONE,
      label=project_filter_label(model, PROJECT_FILTER_NONE),
      message=on_select(PROJECT_FILTER_NONE),
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
/// Project filter shared by the Bot directory and the selected Bot's Chat
/// list. The value stays route metadata; only names are painted.
fn bot_project_filter_row(model : Model) -> @moui.View[Msg] {
  @views.row([
    ui_section(tr(model.lang, "Bots", "Bot")),
    @views.spacer(weight=1.0),
    ui_select_field(
      tr(model.lang, "Project", "项目"),
      bot_project_filter_menu_items(model, fn(value) { BotProjectFilter(value) }),
      model.bot_project_filter,
      model.bot_project_filter_open,
      BotProjectFilterPicker(!model.bot_project_filter_open),
      if model.project.projects_loaded {
        tr(model.lang, "All projects", "全部项目")
      } else {
        tr(model.lang, "Loading projects...", "正在加载项目...")
      },
      236.0,
    ),
  ], spacing=10.0, align=@style.CrossAlign::End).frame(width=992.0)
}

///|
fn bot_directory_row(
  model : Model,
  record : @contracts.BotRecord,
  selected : Bool,
) -> @moui.View[Msg] {
  let activity = bot_recent_activity(model, record)
  let latest = latest_chat_for_bot(model.chats, record.id)
  let name = bot_name(record)
  let recent = match latest {
    Some(chat) => {
      let suffix = if activity == "" { "" } else { " · " + activity }
      chat.title + suffix
    }
    None =>
      if activity == "" {
        tr(model.lang, "No recent Chat activity", "暂无最近对话活动")
      } else {
        activity
      }
  }
  let shown_name = ui_truncate(name, 220.0, 11.0)
  let shown_recent = ui_truncate(recent, 600.0, 9.0)
  @views.container(
    @views.padding_edges(
      @views.row([
        @views.container(
          @views.text(
            bot_initial(name),
            align=@core.TextAlign::TextCenter,
          ).font(ui_font(9.0, 620)).foreground(ui_on_ink()),
          width=22.0,
          height=22.0,
          background=ui_ink(),
          corner_radius=11.0,
          padding=0.0,
        ),
        @views.column([
          @views.row([
            @views.text(
              shown_name,
              width=220.0,
              align=@core.TextAlign::TextStart,
              wrap=false,
            ).font(ui_font(11.0, if selected { 620 } else { 540 })).foreground(
              ui_text_color(),
            ),
            ui_tag(if record.state == "" {
              tr(model.lang, "idle", "空闲")
            } else {
              record.state
            }),
          ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=330.0),
          @views.text(
            shown_recent,
            width=600.0,
            align=@core.TextAlign::TextStart,
            wrap=false,
          ).font(ui_font(9.0, 400)).foreground(ui_dim()),
        ], spacing=2.0, align=@style.CrossAlign::Start).frame(width=600.0),
        @views.spacer(weight=1.0),
        @views.text(
          if selected {
            tr(model.lang, "open", "已打开")
          } else {
            tr(model.lang, "view", "查看")
          },
          align=@core.TextAlign::TextEnd,
        ).font(ui_font(9.0, 500)).foreground(ui_dim()),
      ], spacing=9.0, align=@style.CrossAlign::Center).frame(width=968.0),
      top=7.0,
      right=12.0,
      bottom=7.0,
      left=12.0,
    ),
    width=992.0,
    background=if selected { ui_selected() } else { clear_color() },
    corner_radius=3.0,
    padding=0.0,
  ).on_tap(OpenBotDetail(record.id)).cursor(
    @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
  )
}

///|
fn bot_directory_rows(model : Model, selected_bot : String) -> Array[@moui.View[Msg]] {
  let rows : Array[@moui.View[Msg]] = []
  let bots = bots_in_project(model, model.bot_project_filter)
  if !model.bots_loaded {
    rows.push(
      @views.text(
        tr(model.lang, "Loading Bots from the host...", "正在从主机加载 Bot..."),
        width=992.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_dim()),
    )
  } else if bots.is_empty() {
    rows.push(
      @views.text(
        tr(
          model.lang,
          "No Bot matches this Project filter. Bot membership is derived from active Chat participants; the host exposes no project.membership.list RPC.",
          "没有 Bot 符合此项目筛选。Bot 成员资格来自对话中的有效参与者；主机未暴露 project.membership.list RPC。",
        ),
        width=992.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_dim()),
    )
  } else {
    for record in bots {
      rows.push(bot_directory_row(model, record, record.id == selected_bot))
      rows.push(ui_divider_soft())
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
        ui_truncate(
          if task.goal == "" {
            task.status
          } else {
            task.status + " · " + task.goal
          },
          310.0,
          8.5,
        ),
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
        background=clear_color(),
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
            ui_truncate(automation.title, 260.0, 9.5),
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
  // A Chat carries the Project id. Membership is only claimed when an active
  // participant in a projected Project Chat is this Bot; no membership RPC
  // exists yet, so the window never guesses access.
  let project_rows : Array[@moui.View[Msg]] = []
  for project in model.project.projects {
    let mut chat_count = 0
    for chat in model.chats {
      if chat.project_id == project.id &&
        (chat.bot_id == bot.id || chat.participants.contains(bot.id)) {
        chat_count = chat_count + 1
      }
    }
    if chat_count > 0 {
      project_rows.push(
        @views.container(
          @views.padding_edges(
            @views.row([
              @views.lucide_icon("folder", size=11.0, color=ui_dim()),
              @views.text(
                ui_truncate(project_name(project), 270.0, 9.0),
                width=270.0,
                align=@core.TextAlign::TextStart,
                wrap=false,
              ).font(ui_font(9.0, 540)).foreground(ui_text_color()),
              @views.spacer(weight=1.0),
              @views.text(
                chat_count.to_string() +
                tr(model.lang, " Chats", " 个 Chat"),
                align=@core.TextAlign::TextEnd,
              ).font(mono_font(8.5, 400)).foreground(ui_dim()),
            ], spacing=6.0, align=@style.CrossAlign::Center).frame(width=378.0),
            top=5.0,
            right=6.0,
            bottom=5.0,
            left=6.0,
          ),
          width=390.0,
          background=clear_color(),
          padding=0.0,
        ).on_tap(SelectProject(project.id)).cursor(
          @core.CursorStyle::Icon(@core.CursorIcon::CursorPointer),
        ),
      )
    }
  }
  if project_rows.is_empty() {
    content.push(
      @views.text(
        tr(
          model.lang,
          "No Project Chat membership evidence for this Bot yet.",
          "此 Bot 尚无项目对话成员证据。",
        ),
        width=390.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(8.5, 400)).foreground(ui_dim()),
    )
  } else {
    for row in project_rows {
      content.push(row)
    }
  }
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
  let chats = bot_chats_filtered(model, bot.id, model.bot_project_filter)
  let rows : Array[@moui.View[Msg]] = [
    bot_project_filter_row(model),
  ]
  for row in bot_directory_rows(model, bot.id) {
    rows.push(row)
  }
  rows.push(ui_divider_soft())
  rows.push(
    @views.row([
      @views.text(
        tr(model.lang, "Chats with ", "与 ") + bot.name,
        align=@core.TextAlign::TextStart,
      ).font(ui_font(12.0, 620)).foreground(ui_text_color()),
      ui_tag(project_filter_label(model, model.bot_project_filter)),
      @views.spacer(weight=1.0),
      @views.text(
        chats.length().to_string(),
        align=@core.TextAlign::TextEnd,
      ).font(mono_font(9.0, 400)).foreground(ui_dim()),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=992.0),
  )
  if model.bot_project_filter == PROJECT_FILTER_NONE {
    rows.push(
      @views.text(
        tr(
          model.lang,
          "No-project Chats appear only here in the Bot view; they never enter a Project view.",
          "无项目对话只在此 Bot 视图出现，不会进入项目视图。",
        ),
        width=992.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(9.5, 400)).foreground(ui_dim()),
    )
  }
  if chats.is_empty() {
    rows.push(
      @views.text(
        tr(
          model.lang,
          "No Chat matches this Project filter yet.",
          "此项目筛选下尚无对话。",
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
    for record in chats {
      let chat = chat_identity_for(model, record)
      rows.push(
        @views.container(
          @views.padding_edges(
            @views.row([
              @views.text(
                ui_truncate(chat.title, 520.0, 12.0),
                width=520.0,
                align=@core.TextAlign::TextStart,
                wrap=false,
              ).font(ui_font(12.0, 560)).foreground(ui_text_color()),
              @views.text(
                ui_truncate(
                  chat_project_label(model, chat.project_id),
                  160.0,
                  9.5,
                ),
                width=160.0,
                align=@core.TextAlign::TextStart,
                wrap=false,
              ).font(ui_font(9.5, 400)).foreground(ui_muted()),
              if chat.agent_name == "" {
                ui_meta("")
              } else {
                @views.text(
                  ui_truncate(chat.agent_name, 120.0, 9.0),
                  width=120.0,
                  align=@core.TextAlign::TextStart,
                  wrap=false,
                ).font(ui_font(9.0, 400)).foreground(ui_dim())
              },
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
    background=clear_color(),
    padding=0.0,
  )
}

///|
fn agent_lifecycle_label(model : Model, state : String) -> String {
  match state {
    @contracts.AGENT_LIFECYCLE_ACTIVE => tr(model.lang, "active", "可用")
    @contracts.AGENT_LIFECYCLE_SUSPENDED => tr(model.lang, "suspended", "已暂停")
    @contracts.AGENT_LIFECYCLE_RETIRED => tr(model.lang, "retired", "已停用")
    @contracts.AGENT_LIFECYCLE_PROVISIONING =>
      tr(model.lang, "provisioning", "创建中")
    "" => tr(model.lang, "unknown", "未知")
    _ => state
  }
}

///|
fn agent_software_menu_items(
  bot : @contracts.BotRecord,
  on_select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = []
  for software in bot.software_allowlist {
    items.push(
      @views.MenuItem::new(
        id=software,
        label=software,
        message=on_select(software),
      ),
    )
  }
  items
}

///|
fn bot_agent_row(
  model : Model,
  agent : @contracts.AgentRecord,
) -> @moui.View[Msg] {
  let state = if agent.state == "" {
    @contracts.AGENT_LIFECYCLE_PROVISIONING
  } else {
    agent.state
  }
  let software = agent.runtime_binding.software_id
  let when = if agent.updated_at != "" {
    compact_time(agent.updated_at)
  } else {
    compact_time(agent.created_at)
  }
  let actions : Array[@moui.View[Msg]] = []
  if state == @contracts.AGENT_LIFECYCLE_ACTIVE {
    actions.push(
      ui_ghost_small(
        tr(model.lang, "Suspend", "暂停"),
        SuspendBotAgent(agent.id),
      ),
    )
  }
  if state != @contracts.AGENT_LIFECYCLE_RETIRED {
    actions.push(
      ui_ghost_small(
        tr(model.lang, "Retire", "停用"),
        RetireBotAgent(agent.id),
      ),
    )
  }
  @views.container(
    @views.padding_edges(
      @views.row([
        @views.column([
          @views.row([
            @views.text(
              if agent.name == "" {
                tr(model.lang, "Unnamed Agent", "未命名 Agent")
              } else {
                agent.name
              },
              width=330.0,
              align=@core.TextAlign::TextStart,
              wrap=false,
            ).font(ui_font(11.0, 580)).foreground(ui_text_color()),
            ui_tag(agent_lifecycle_label(model, state)),
            if software == "" {
              ui_meta("")
            } else {
              @views.text(
                software,
                align=@core.TextAlign::TextStart,
              ).font(mono_font(9.0, 400)).foreground(ui_muted())
            },
          ], spacing=7.0, align=@style.CrossAlign::Center).frame(width=640.0),
          @views.text(
            if agent.specialty == "" {
              tr(
                model.lang,
                "Execution worker · no specialty recorded",
                "执行器 · 未记录专长",
              )
            } else {
              agent.specialty
            },
            width=640.0,
            align=@core.TextAlign::TextStart,
            wrap=false,
          ).font(ui_font(9.0, 400)).foreground(ui_dim()),
        ], spacing=3.0, align=@style.CrossAlign::Start).frame(width=640.0),
        @views.spacer(weight=1.0),
        if when == "" { ui_meta("") } else { ui_mono(when, 8.5) },
        @views.row(actions, spacing=5.0, align=@style.CrossAlign::Center),
      ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
      top=9.0,
      right=14.0,
      bottom=9.0,
      left=14.0,
    ),
    width=992.0,
    background=ui_surface(),
    border=Some(ui_border_style(ui_border_soft(), 1.0)),
    corner_radius=4.0,
    padding=0.0,
  )
}

///|
fn bot_agent_create_form(
  model : Model,
  bot : @contracts.BotRecord,
) -> Array[@moui.View[Msg]] {
  let draft = model.agent_draft
  let fields : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Create Agent", "创建 Agent")),
    @views.row([
      ui_field(
        tr(model.lang, "Name", "名称"),
        draft.name,
        fn(value) { AgentDraftName(value) },
        tr(model.lang, "e.g. Ada · coding", "例如：Ada · coding"),
        300.0,
      ),
      if bot.software_allowlist.is_empty() {
        ui_field(
          tr(model.lang, "Software", "软件"),
          draft.software,
          fn(value) { AgentDraftSoftware(value) },
          tr(model.lang, "software name", "软件名称"),
          300.0,
        )
      } else {
        ui_select_field(
          tr(model.lang, "Software", "软件"),
          agent_software_menu_items(bot, fn(value) { AgentDraftSoftware(value) }),
          draft.software,
          draft.software_picker_open,
          AgentDraftSoftwarePicker(!draft.software_picker_open),
          tr(model.lang, "Select software", "选择软件"),
          300.0,
        )
      },
      ui_field(
        tr(model.lang, "Specialty", "专长"),
        draft.specialty,
        fn(value) { AgentDraftSpecialty(value) },
        tr(model.lang, "optional", "可选"),
        260.0,
      ),
    ], spacing=12.0, align=@style.CrossAlign::End).frame(width=960.0),
    @views.row([
      @views.column([
        ui_field_label(tr(model.lang, "Launch", "启动方式")),
        @views.row([
          ui_choice_segment(
            "ACP",
            draft.launch_kind == @contracts.RUNTIME_LAUNCH_ACP,
            AgentDraftLaunch(@contracts.RUNTIME_LAUNCH_ACP),
          ),
          ui_choice_segment(
            tr(model.lang, "Command", "命令"),
            draft.launch_kind == @contracts.RUNTIME_LAUNCH_COMMAND,
            AgentDraftLaunch(@contracts.RUNTIME_LAUNCH_COMMAND),
          ),
        ], spacing=6.0, align=@style.CrossAlign::Center),
      ], spacing=5.0, align=@style.CrossAlign::Start),
      @views.spacer(weight=1.0),
      ui_primary(
        if draft.busy {
          tr(model.lang, "Creating...", "正在创建...")
        } else {
          tr(model.lang, "Create Agent", "创建 Agent")
        },
        BotAgentCreateSubmit,
      ),
    ], spacing=12.0, align=@style.CrossAlign::End).frame(width=960.0),
  ]
  if draft.launch_kind == @contracts.RUNTIME_LAUNCH_COMMAND {
    fields.push(
      @views.row([
        ui_field(
          tr(model.lang, "Command", "命令"),
          draft.command,
          fn(value) { AgentDraftCommand(value) },
          tr(model.lang, "runtime executable", "运行时可执行文件"),
          380.0,
        ),
        ui_field(
          tr(model.lang, "Arguments", "参数"),
          draft.args,
          fn(value) { AgentDraftArgs(value) },
          tr(model.lang, "space-separated", "以空格分隔"),
          560.0,
        ),
      ], spacing=12.0, align=@style.CrossAlign::End).frame(width=960.0),
    )
  }
  if bot.software_allowlist.is_empty() {
    fields.push(
      ui_muted_wrapped(
        tr(
          model.lang,
          "This Bot projects no software allowlist. The host accepts the software name entered above; no agent id is typed.",
          "此 Bot 未投影软件允许列表。主机会接受上方输入的软件名称；无需输入 Agent ID。",
        ),
        960.0,
      ),
    )
  }
  match bot.create_policy {
    @contracts.BOT_CREATE_POLICY_OFF =>
      fields.push(
        @views.text(
          tr(
            model.lang,
            "This Bot's create policy is off; the host will reject new Agents.",
            "此 Bot 的创建策略为关闭；主机会拒绝新的 Agent。",
          ),
          width=960.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(10.0, 400)).foreground(ui_warning()),
      )
    @contracts.BOT_CREATE_POLICY_ASK =>
      fields.push(
        @views.text(
          tr(
            model.lang,
            "This Bot's create policy is ask. The host requires an owner Decision id; this P1 form does not invent one, so creation will be rejected until the policy is changed outside this flow.",
            "此 Bot 的创建策略为询问。主机要求所有者决策 ID；此 P1 表单不会编造该 ID，因此在流程外更改策略前，创建会被拒绝。",
          ),
          width=960.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(10.0, 400)).foreground(ui_warning()),
      )
    _ => ()
  }
  if draft.message != "" {
    fields.push(ui_muted_wrapped(draft.message, 960.0))
  } else if model.chat_error.has_prefix("bot.agent.") {
    fields.push(
      @views.text(
        model.chat_error,
        width=960.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_danger()),
    )
  }
  fields
}

///|
fn bot_agents_tab(model : Model) -> @moui.View[Msg] {
  let bot_identity = active_bot_identity(model)
  let bot_record = bot_by_id(model.bots, bot_identity.id)
  let rows : Array[@moui.View[Msg]] = [
    @views.row([
      @views.text(
        tr(model.lang, "Agents", "Agents"),
        align=@core.TextAlign::TextStart,
      ).font(ui_font(13.0, 620)).foreground(ui_text_color()),
      @views.spacer(weight=1.0),
      @views.text(
        bot_identity.name,
        align=@core.TextAlign::TextEnd,
      ).font(ui_font(9.5, 400)).foreground(ui_muted()),
      ui_ghost_small(
        tr(model.lang, "Refresh", "刷新"),
        SelectBotTab(BotAgents),
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=992.0),
  ]
  if !bot_agents_loaded_for(model, bot_identity.id) {
    rows.push(
      @views.text(
        tr(model.lang, "Loading Agents from the host...", "正在从主机加载 Agent..."),
        width=992.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_dim()),
    )
  } else if model.bot_agents.is_empty() {
    rows.push(
      @views.text(
        tr(
          model.lang,
          "No Agents for this Bot yet. Create one by name and software below.",
          "此 Bot 尚无 Agent。请在下方按名称和软件创建。",
        ),
        width=992.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(10.0, 400)).foreground(ui_dim()),
    )
  } else {
    for agent in model.bot_agents {
      rows.push(bot_agent_row(model, agent))
    }
  }
  rows.push(ui_divider_soft())
  match bot_record {
    Some(record) => {
      for field in bot_agent_create_form(model, record) {
        rows.push(field)
      }
    }
    None =>
      rows.push(
        @views.text(
          tr(
            model.lang,
            "Open a projected Bot before creating an Agent.",
            "请先打开一个已投影的 Bot，再创建 Agent。",
          ),
          width=992.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(ui_font(10.0, 400)).foreground(ui_warning()),
      )
  }
  rows.push(ui_divider_soft())
  rows.push(
    ui_advanced_control(
      model.lang,
      model.bot_agent_manage,
      SetBotAgentManage(!model.bot_agent_manage),
    ),
  )
  rows.push(
    @views.text(
      tr(
        model.lang,
        "Legacy session controls stay reachable; Chat owns the visible thread.",
        "旧会话控制仍可访问；可见线程由 Chat 承载。",
      ),
      width=992.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(9.0, 400)).foreground(ui_dim()),
  )
  if model.bot_agent_manage {
    rows.push(agents_page(model))
  }
  @views.container(
    @views.padding_edges(
      @views.scroll_view(
        @views.column(rows, spacing=10.0, align=@style.CrossAlign::Start).frame(
          width=992.0,
        ),
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
    background=clear_color(),
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
    background=clear_color(),
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
  let summary = bot.summary +
    " · " +
    chats.length().to_string() +
    tr(model.lang, " Chats", " 个 Chat")
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
              ui_truncate(bot.name, 300.0, 21.0),
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
            ui_truncate(summary, 430.0, 10.0),
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
    background=clear_color(),
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
    height=32.0,
    background=clear_color(),
    padding=0.0,
  )
  @views.container(
    @views.column([
      header,
      tabs,
      ui_divider_soft(),
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
