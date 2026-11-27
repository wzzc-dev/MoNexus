///|
/// The MoNexus desktop shell and its eight pages.
///
/// Layout contract (1280x800): 8pt outer margin, two islands with an 8pt gap.
/// The 224pt sidebar owns navigation; the 1032pt main island is a 44pt top
/// bar, a scrolling 992pt body, and a 26pt status bar. Every colour, font and
/// radius comes from `theme.mbt`/`ui.mbt`; this file only composes.

///|
using @views {
  checkbox,
  column,
  container,
  lucide_icon,
  padding,
  padding_edges,
  padding_xy,
  row,
  scroll_view,
  spacer,
  text,
}

///|
fn page_icon(page : Page) -> String {
  match page {
    Home => "house"
    Machines => "server"
    Projects => "folder"
    Agents => "message-circle"
    Inbox => "mail"
    Tasks => "list"
    Search => "search"
    Settings => "settings"
  }
}

///|
fn link_tone(link : LinkState) -> @core.Color {
  match link {
    Online => ui_success()
    Connecting => ui_warning()
    Offline => ui_danger()
  }
}

///|
fn clear_color() -> @core.Color {
  @core.Color::rgba(r=0.0, g=0.0, b=0.0, a=0.0)
}

///|
fn inbox_needs_count(model : Model) -> Int {
  let mut count = 0
  for decision in model.inbox.decisions {
    if inbox_bucket_of(decision) == @contracts.INBOX_NEEDS_YOU {
      count = count + 1
    }
  }
  count
}

///|
fn list_has(values : Array[String], value : String) -> Bool {
  for item in values {
    if item == value {
      return true
    }
  }
  false
}

///|
fn machine_menu_items(
  model : Model,
  select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = [
    @views.MenuItem::new(
      id="",
      label=tr(model.lang, "Local machine", "本地机器"),
      message=select(""),
    ),
  ]
  for record in model.machines {
    let label = machine_display_name(model.machines, record.id, model.lang)
    items.push(
      @views.MenuItem::new(
        id=record.id,
        label~,
        message=select(record.id),
      ),
    )
  }
  items
}

///|
fn workspace_menu_items(
  model : Model,
  select : (String) -> Msg,
) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = []
  for record in model.project.workspaces {
    items.push(
      @views.MenuItem::new(
        id=record.id,
        label=workspace_choice_label(model.machines, record, model.lang),
        message=select(record.id),
      ),
    )
  }
  items
}

///|
fn agent_menu_items(model : Model) -> Array[@views.MenuItem[Msg]] {
  let default_label = tr(model.lang, "Default agent", "默认智能体")
  let items : Array[@views.MenuItem[Msg]] = [
    @views.MenuItem::new(
      id="default",
      label=default_label,
      message=AgentSelect("default"),
    ),
  ]
  let seen : Array[String] = ["default"]
  let mut recent_index = 1
  for record in model.agent.sessions {
    if record.agent_id != "" && !list_has(seen, record.agent_id) {
      let label = if record.agent_name != "" {
        record.agent_name
      } else {
        tr(model.lang, "Recent agent ", "最近智能体 ") +
        recent_index.to_string()
      }
      items.push(
        @views.MenuItem::new(
          id=record.agent_id,
          label~,
          message=AgentSelect(record.agent_id),
        ),
      )
      seen.push(record.agent_id)
      recent_index = recent_index + 1
    }
  }
  items
}

///|
fn session_menu_items(model : Model) -> Array[@views.MenuItem[Msg]] {
  let items : Array[@views.MenuItem[Msg]] = []
  let mut index = 1
  for record in model.agent.sessions {
    let label = tr(model.lang, "Session ", "会话 ") +
      index.to_string() +
      " · " +
      record.state +
      tr(model.lang, " · turns ", " · 轮次 ") +
      record.turns.to_string()
    items.push(
      @views.MenuItem::new(
        id=record.id,
        label~,
        message=AgentSelectSession(record.id),
      ),
    )
    index = index + 1
  }
  items
}

///|
fn workspace_name_for(model : Model, workspace_id : String) -> String {
  if workspace_id == "" {
    return tr(model.lang, "(none)", "（无）")
  }
  match workspace_by_id(model.project.workspaces, workspace_id) {
    Some(record) => workspace_display_name(record)
    None => tr(model.lang, "not currently open", "当前未打开")
  }
}

///|
fn machine_name_for(model : Model, machine_id : String) -> String {
  if machine_id == "" {
    return tr(model.lang, "Local machine", "本地机器")
  }
  for record in model.machines {
    if record.id == machine_id {
      return if record.name == "" {
        tr(model.lang, "Unnamed machine", "未命名机器")
      } else {
        record.name
      }
    }
  }
  tr(model.lang, "Machine unavailable", "机器不可用")
}

///|
fn agent_name_for(model : Model, agent_id : String) -> String {
  for item in agent_menu_items(model) {
    if item.id == agent_id {
      return item.label
    }
  }
  tr(model.lang, "Custom agent", "自定义智能体")
}

///|
fn task_title_for(model : Model, task_id : String) -> String {
  for record in model.task.tasks {
    if record.id == task_id {
      return record.title
    }
  }
  tr(model.lang, "Selected task", "已选任务")
}

///|
/// Left navigation row: 32pt tall, Lucide glyph + label, accent tint when the
/// page is open and a hover wash otherwise. The Inbox row carries its needs-you
/// count.
fn nav_item(model : Model, page : Page) -> @moui.View[Msg] {
  let label = page.label_in(model.lang)
  let active = model.page == page
  let hover_key = "nav:" + page.label()
  let hovered = model.hover_row == hover_key
  let tone = if active {
    ui_accent()
  } else if hovered {
    ui_text_color()
  } else {
    ui_muted()
  }
  let background = if active {
    ui_accent_soft()
  } else if hovered {
    ui_hover()
  } else {
    clear_color()
  }
  let children : Array[@moui.View[Msg]] = [
    lucide_icon(page_icon(page), size=16.0, color=tone),
    text(label, align=@core.TextAlign::TextStart).font(ui_font(13.0, if active { 600 } else { 400 }))
    .foreground(tone),
    spacer(weight=1.0),
  ]
  if page == Inbox {
    let needs = inbox_needs_count(model)
    if needs > 0 {
      children.push(ui_pill(needs.to_string(), active))
    }
  }
  container(
    padding_xy(
      row(children, spacing=10.0, align=@style.CrossAlign::Center).frame(
        width=184.0,
      ),
      horizontal=10.0,
    ),
    height=32.0,
    background=background,
    corner_radius=7.0,
    padding=0.0,
  ).on_tap(SelectPage(page)).on_hover(
    fn(over) { HoverRow(hover_key, over) },
  ).cursor(@core.CursorStyle::Icon(@core.CursorIcon::CursorPointer))
}

///|
fn brand_mark() -> @moui.View[Msg] {
  container(
    text("M").font(serif_font(15.0)).foreground(ui_on_accent()),
    width=24.0,
    height=24.0,
    background=ui_accent(),
    corner_radius=7.0,
    padding=0.0,
  )
}

///|
fn sidebar(model : Model) -> @moui.View[Msg] {
  let items : Array[@moui.View[Msg]] = []
  for page in [Home, Machines, Projects, Agents, Inbox, Tasks, Search] {
    items.push(nav_item(model, page))
  }
  let content = column([
    container(
      padding_edges(
        row([
          brand_mark(),
          text("MoNexus", align=@core.TextAlign::TextStart).font(ui_font(15.0, 600)).foreground(ui_text_color()),
        ], spacing=9.0, align=@style.CrossAlign::Center).frame(width=196.0),
        top=0.0,
        right=14.0,
        bottom=0.0,
        left=14.0,
      ),
      height=44.0,
      padding=0.0,
    ),
    padding_edges(
      column(items, spacing=2.0),
      top=8.0,
      right=10.0,
      bottom=0.0,
      left=10.0,
    ),
    spacer(weight=1.0),
    ui_divider_soft(),
    padding_edges(
      column([nav_item(model, Settings)], spacing=0.0),
      top=10.0,
      right=10.0,
      bottom=8.0,
      left=10.0,
    ),
    padding_edges(
      ui_mono(@contracts.PRODUCT_VERSION, 10.0).frame(width=196.0),
      top=0.0,
      right=14.0,
      bottom=10.0,
      left=14.0,
    ),
  ], spacing=0.0).frame(width=ui_sidebar_width, height=ui_sidebar_height)
  ui_panel(content, width=ui_sidebar_width, height=ui_sidebar_height)
}

///|
fn page_refresh_msg(model : Model) -> Msg? {
  match model.page {
    Machines => Some(RefreshMachines)
    Projects => Some(ProjectRefresh)
    Agents => Some(AgentRefresh)
    Inbox => Some(InboxRefresh)
    Tasks => Some(TasksRefresh)
    _ => None
  }
}

///|
fn top_bar(model : Model) -> @moui.View[Msg] {
  let children : Array[@moui.View[Msg]] = [
    ui_page_title(model.page.label_in(model.lang)),
    spacer(weight=1.0),
    ui_state_pill(
      tr(model.lang, "host ", "主机 ") +
      model.host.link.label_in(model.lang),
      link_tone(model.host.link),
    ),
  ]
  match page_refresh_msg(model) {
    Some(msg) =>
      children.push(
        ui_ghost_compact(tr(model.lang, "Refresh", "刷新"), msg, 64.0),
      )
    None => ()
  }
  container(
    padding_xy(
      row(children, spacing=10.0, align=@style.CrossAlign::Center).frame(
        width=992.0,
      ),
      horizontal=20.0,
    ),
    height=ui_topbar_height,
    padding=0.0,
  )
}

///|
fn status_bar(model : Model) -> @moui.View[Msg] {
  let host = model.host
  let left = if host.host_id == "" {
    tr(model.lang, "not connected", "未连接")
  } else {
    host.host_id
  }
  let right = if model.clipboard_note != "" {
    model.clipboard_note
  } else if host.event_count > 0 {
    tr(model.lang, "events: ", "事件：") +
    host.event_count.to_string() +
    tr(model.lang, " · seq ", " · 序号 ") +
    host.event_seq.to_string()
  } else {
    "MoNexus " + @contracts.PRODUCT_VERSION +
    tr(model.lang, " · 8 pages", " · 8 个页面")
  }
  container(
    padding_xy(
      row([
        ui_mono(left, 10.5),
        spacer(weight=1.0),
        ui_mono(right, 10.5),
      ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=992.0),
      horizontal=20.0,
    ),
    height=ui_statusbar_height,
    padding=0.0,
  )
}

///|
// MARK: - Home

fn home_page(model : Model) -> @moui.View[Msg] {
  let host = model.host
  let stats = row([
    ui_stat_card(
      tr(model.lang, "Machines", "机器"),
      model.machines.length().to_string(),
      if model.machines.is_empty() {
        tr(model.lang, "none registered", "未注册")
      } else {
        tr(model.lang, "registered", "已注册")
      },
      322.0,
    ),
    ui_stat_card(
      tr(model.lang, "Decisions", "决策"),
      model.inbox.decisions.length().to_string(),
      if model.inbox.decisions.is_empty() {
        tr(model.lang, "inbox empty", "收件箱为空")
      } else {
        tr(model.lang, "in the inbox", "位于收件箱")
      },
      322.0,
    ),
    ui_stat_card(
      tr(model.lang, "Tasks", "任务"),
      model.task.tasks.length().to_string(),
      if model.task.tasks.is_empty() {
        tr(model.lang, "board empty", "看板为空")
      } else {
        tr(model.lang, "on the board", "位于看板")
      },
      322.0,
    ),
  ], spacing=12.0).frame(width=992.0)
  let connection : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Connection", "连接")),
    ui_kv(tr(model.lang, "state", "状态"), host.link.label_in(model.lang), 960.0),
    ui_kv(
      tr(model.lang, "host id", "主机 ID"),
      if host.host_id == "" {
        tr(model.lang, "(not connected)", "（未连接）")
      } else {
        host.host_id
      },
      960.0,
    ),
    ui_kv(
      tr(model.lang, "endpoint", "端点"),
      if host.ws_url == "" {
        tr(model.lang, "(waiting for host.json)", "（等待 host.json）")
      } else {
        host.ws_url
      },
      960.0,
    ),
    ui_kv(
      tr(model.lang, "version", "版本"),
      if host.version == "" {
        tr(model.lang, "(not connected)", "（未连接）")
      } else {
        host.version
      },
      960.0,
    ),
    ui_kv(
      tr(model.lang, "events", "事件"),
      if host.event_count == 0 {
        tr(model.lang, "none yet", "暂无")
      } else {
        host.event_count.to_string() +
        tr(model.lang, " · last ", " · 最近 ") +
        host.last_event +
        " @" +
        host.event_seq.to_string()
      },
      960.0,
    ),
  ]
  if host.last_error != "" {
    connection.push(
      text(
        tr(model.lang, "reason: ", "原因：") + host.last_error,
        width=960.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(11.0, 400)).foreground(ui_danger()),
    )
  }
  column([
    ui_hero(tr(model.lang, "Welcome to MoNexus", "欢迎使用 MoNexus")),
    ui_muted_wrapped(
      tr(
        model.lang,
        "A local-first desktop shell for machines, tasks and agent sessions.",
        "面向机器、任务和智能体会话的本地优先桌面外壳。",
      ),
      620.0,
    ),
    stats,
    ui_card(connection, width=992.0),
  ], spacing=16.0)
}

///|
// MARK: - Machines

fn machine_card(
  model : Model,
  record : @contracts.MachineRecord,
) -> @moui.View[Msg] {
  let status = machine_status_text_in(record.status, model.lang)
  let identity = if record.identity == "" {
    tr(model.lang, "(default)", "（默认）")
  } else {
    record.identity
  }
  let children : Array[@moui.View[Msg]] = [
    row([
      column([
        ui_row_title(record.name),
        ui_mono(record.id, 10.5),
      ], spacing=3.0, align=@style.CrossAlign::Start),
      spacer(weight=1.0),
      ui_tag(status),
    ], spacing=12.0, align=@style.CrossAlign::Center).frame(width=960.0),
    row([
      ui_mono(record.target_label() + ":" + record.port.to_string(), 11.0),
      ui_meta(tr(model.lang, "identity ", "身份 ") + identity),
      ui_meta(
        tr(model.lang, "config ", "配置 ") +
        (if record.use_ssh_config {
          tr(model.lang, "on", "开")
        } else {
          tr(model.lang, "off", "关")
        }),
      ),
      spacer(weight=1.0),
    ], spacing=12.0, align=@style.CrossAlign::Center).frame(width=960.0),
    ui_meta(
      tr(model.lang, "host keys ", "主机密钥 ") +
      record.host_key_policy +
      " · " +
      machine_profile_summary_in(record, model.lang),
    ),
  ]
  if record.last_error != "" {
    children.push(
      text(
        tr(model.lang, "reason: ", "原因：") + record.last_error,
        width=900.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(11.0, 400)).foreground(ui_danger()),
    )
  }
  let actions : Array[@moui.View[Msg]] = [
    ui_ghost_small(tr(model.lang, "Probe", "探测"), ProbeMachine(record.id)),
    ui_danger_ghost(
      tr(model.lang, "Remove", "移除"),
      RemoveMachine(record.id),
    ),
  ]
  if model.machine_busy == record.id {
    actions.push(ui_meta(tr(model.lang, "working...", "处理中...")))
  }
  children.push(row(actions, spacing=8.0, align=@style.CrossAlign::Center))
  ui_card(children, width=992.0)
}

///|
fn machines_page(model : Model) -> @moui.View[Msg] {
  let draft = model.draft
  let form : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Add machine", "添加机器")),
    row([
      ui_field(
        tr(model.lang, "Name", "名称"),
        draft.name,
        fn(value) { DraftName(value) },
        tr(model.lang, "name", "名称"),
        220.0,
      ),
      ui_field(
        tr(model.lang, "Host", "主机"),
        draft.host,
        fn(value) { DraftHost(value) },
        tr(model.lang, "host (required)", "主机（必填）"),
        280.0,
      ),
      ui_field(
        tr(model.lang, "Port", "端口"),
        draft.port,
        fn(value) { DraftPort(value) },
        tr(model.lang, "port", "端口"),
        90.0,
      ),
      ui_field(
        tr(model.lang, "User", "用户"),
        draft.user,
        fn(value) { DraftUser(value) },
        tr(model.lang, "user", "用户"),
        160.0,
      ),
    ], spacing=12.0, align=@style.CrossAlign::End),
    row([
      ui_field(
        tr(model.lang, "Identity file", "身份文件"),
        draft.identity,
        fn(value) { DraftIdentity(value) },
        tr(model.lang, "identity file (optional)", "身份文件（可选）"),
        320.0,
      ),
      checkbox(
        tr(model.lang, "use ~/.ssh/config", "使用 ~/.ssh/config"),
        checked=draft.use_ssh_config,
        on_change=fn(value) { DraftUseConfig(value) },
      ),
      spacer(weight=1.0),
      ui_ghost(
        tr(model.lang, "host keys: ", "主机密钥：") +
        draft.host_key_policy,
        CycleDraftPolicy,
      ),
      ui_primary(tr(model.lang, "Add machine", "添加机器"), SubmitMachine),
    ], spacing=12.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if model.machine_message != "" {
    form.push(ui_muted_wrapped(model.machine_message, 960.0))
  }
  let registered = model.machines.length().to_string() +
    tr(model.lang, " registered", " 台已注册")
  let saved : Array[@moui.View[Msg]] = [
    row([
      ui_section(tr(model.lang, "Saved machines", "已保存的机器")),
      spacer(weight=1.0),
      ui_meta(registered),
    ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if model.machines.is_empty() {
    saved.push(
      ui_muted_wrapped(
        if model.machines_loaded {
          tr(model.lang, "no machines registered yet", "尚未注册机器")
        } else {
          tr(
            model.lang,
            "loading machines from the host...",
            "正在从主机加载机器...",
          )
        },
        960.0,
      ),
    )
  } else {
    for record in model.machines {
      saved.push(machine_card(model, record))
    }
  }
  column([
    ui_card(form, width=992.0),
    column(saved, spacing=10.0),
  ], spacing=16.0)
}

///|
// MARK: - Projects

fn entry_row(
  model : Model,
  entry : @contracts.WorkspaceEntry,
) -> @moui.View[Msg] {
  let selected = model.project.selected == entry.path
  let tone = if selected { ui_accent() } else { ui_text_color() }
  container(
    padding_xy(
      row([
        lucide_icon(
          if entry.is_dir { "folder" } else { "file" },
          size=14.0,
          color=if selected { ui_accent() } else { ui_dim() },
        ),
        text(
          entry.name,
          width=560.0,
          align=@core.TextAlign::TextStart,
          wrap=false,
        ).font(mono_font(11.0, 400)).foreground(tone),
        spacer(weight=1.0),
        ui_ghost_small(
          if entry.is_dir {
            tr(model.lang, "list", "列表")
          } else {
            tr(model.lang, "open", "打开")
          },
          if entry.is_dir {
            ProjectOpenDir(entry.path)
          } else {
            ProjectOpenFile(entry.path)
          },
        ),
      ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=944.0),
      horizontal=8.0,
    ),
    height=30.0,
    background=if selected { ui_accent_soft() } else { clear_color() },
    corner_radius=6.0,
    padding=0.0,
  )
}

///|
fn workspace_row(
  model : Model,
  record : @contracts.WorkspaceRecord,
) -> @moui.View[Msg] {
  let selected = match model.project.workspace {
    Some(current) => current.id == record.id
    None => false
  }
  let actions : Array[@moui.View[Msg]] = [
    column([
      ui_row_title(record.name),
      ui_mono(record.root, 11.0),
    ], spacing=3.0, align=@style.CrossAlign::Start),
    spacer(weight=1.0),
    ui_tag(
      if record.is_git {
        "git"
      } else {
        tr(model.lang, "exclusive", "独占")
      },
    ),
  ]
  if selected {
    actions.push(
      ui_ghost_small(
        tr(model.lang, "terminal", "终端"),
        ProjectTerminalFocus,
      ),
    )
  }
  actions.push(
    ui_ghost_small(
      tr(model.lang, "restore", "恢复"),
      ProjectSelectWorkspace(record.id),
    ),
  )
  let child = column([
    row(
      actions,
      spacing=12.0,
      align=@style.CrossAlign::Center,
    ).frame(width=964.0),
  ], spacing=6.0).frame(width=964.0)
  container(
    padding(child, 14.0),
    width=992.0,
    background=if selected { ui_accent_soft() } else { ui_surface() },
    corner_radius=10.0,
    border=Some(
      ui_edge(
        if selected {
          ui_accent().multiply_alpha(0.45)
        } else {
          ui_border_soft()
        },
      ),
    ),
    padding=0.0,
  )
}

///|
fn project_detail(model : Model) -> Array[@moui.View[Msg]] {
  let project = model.project
  let detail : Array[@moui.View[Msg]] = []
  match project.workspace {
    Some(record) => {
      let terminal : Array[@moui.View[Msg]] = [
        ui_section(tr(model.lang, "Terminal", "终端")),
        ui_mono_wrapped(
          record.name + " · " + record.root,
          10.5,
          960.0,
          ui_dim(),
        ),
        row([
          ui_primary(
            tr(model.lang, "Open terminal", "打开终端"),
            ProjectTerminalFocus,
          ),
          ui_meta(
            tr(model.lang, "state ", "状态 ") +
            terminal_state_label(project.terminal_state, model.lang) +
            (if project.terminal_id == "" {
              ""
            } else {
              tr(model.lang, " · session ", " · 会话 ") +
              terminal_session_label(project.terminal_id)
            }),
          ),
          spacer(weight=1.0),
        ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
      ]
      detail.push(ui_card(terminal, width=992.0))
      let files : Array[@moui.View[Msg]] = [
        ui_section(tr(model.lang, "Files", "文件")),
        ui_mono_wrapped(
          tr(model.lang, "workspace ", "工作区 ") +
          record.id +
          tr(model.lang, " · root ", " · 根目录 ") +
          record.root +
          " · " +
          (if record.is_git {
            "git"
          } else {
            tr(model.lang, "non-git (exclusive lease)", "非 git（独占租约）")
          }),
          10.5,
          960.0,
          ui_dim(),
        ),
      ]
      if project.entries.is_empty() {
        files.push(
          ui_muted_wrapped(tr(model.lang, "no entries loaded", "未加载条目"), 960.0),
        )
      } else {
        for entry in project.entries {
          files.push(entry_row(model, entry))
        }
      }
      detail.push(ui_card(files, width=992.0))
      let editor : Array[@moui.View[Msg]] = [
        ui_section(tr(model.lang, "Editor", "编辑器")),
        ui_meta(
          if project.selected == "" {
            tr(model.lang, "select a file", "选择文件")
          } else {
            project.selected +
            (if project.dirty {
              tr(model.lang, " · unsaved", " · 未保存")
            } else {
              ""
            })
          },
        ),
        ui_text_area_field(
          tr(model.lang, "Content", "内容"),
          project.content,
          fn(value) { ProjectDraft(value) },
          tr(model.lang, "file content", "文件内容"),
          960.0,
          8,
        ),
        row([
          ui_primary(tr(model.lang, "Save", "保存"), ProjectSaveFile),
          ui_ghost(
            tr(model.lang, "Refresh diff", "刷新差异"),
            ProjectRefreshDiff,
          ),
        ], spacing=8.0, align=@style.CrossAlign::Center),
      ]
      detail.push(ui_card(editor, width=992.0))
      let git : Array[@moui.View[Msg]] = [
        ui_section(tr(model.lang, "Git status", "Git 状态")),
        ui_code_block(
          if project.status_text == "" {
            tr(model.lang, "(not loaded)", "（未加载）")
          } else {
            project.status_text
          },
          960.0,
        ),
        ui_section(tr(model.lang, "Git diff", "Git 差异")),
        ui_code_block(
          if project.diff_text == "" {
            tr(model.lang, "(no diff loaded)", "（未加载差异）")
          } else {
            project.diff_text
          },
          960.0,
        ),
      ]
      detail.push(ui_card(git, width=992.0))
      let worktree : Array[@moui.View[Msg]] = [
        ui_section(tr(model.lang, "Worktree", "工作树")),
        row([
          ui_field(
            tr(model.lang, "Branch", "分支"),
            project.worktree_branch,
            fn(value) { ProjectWorktreeBranch(value) },
            tr(model.lang, "branch", "分支"),
            240.0,
          ),
          ui_field(
            tr(model.lang, "Path", "路径"),
            project.worktree_path,
            fn(value) { ProjectWorktreePath(value) },
            tr(model.lang, "/absolute/worktree/path", "/绝对路径/工作树"),
            440.0,
          ),
          ui_primary(
            tr(model.lang, "Create worktree", "创建工作树"),
            ProjectCreateWorktree,
          ),
        ], spacing=12.0, align=@style.CrossAlign::End),
      ]
      if project.worktree_message != "" {
        worktree.push(ui_meta(project.worktree_message))
      }
      detail.push(ui_card(worktree, width=992.0))
    }
    None =>
      detail.push(
        ui_card([
          ui_muted_wrapped(
            tr(
              model.lang,
              "No project selected. Pick an open workspace in the list above or open a root.",
              "未选择项目。请从上方列表中选择一个打开的工作区，或打开一个根目录。",
            ),
            960.0,
          ),
        ], width=992.0),
      )
  }
  detail
}

///|
fn projects_page(model : Model) -> @moui.View[Msg] {
  let project = model.project
  let open_form : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Open project", "打开项目")),
    row([
      ui_select_field(
        tr(model.lang, "Machine", "机器"),
        machine_menu_items(model, fn(value) { ProjectMachineSelect(value) }),
        project.machine_id,
        project.machine_picker_open,
        ProjectMachineToggle,
        tr(model.lang, "Select a machine", "选择机器"),
        240.0,
      ),
      ui_field(
        tr(model.lang, "Root", "根目录"),
        project.root,
        fn(value) { ProjectRoot(value) },
        tr(model.lang, "/absolute/project/root", "/绝对路径/项目根目录"),
        440.0,
      ),
      ui_primary(tr(model.lang, "Open project", "打开项目"), ProjectOpen),
    ], spacing=12.0, align=@style.CrossAlign::End),
  ]
  if project.advanced {
    open_form.push(
      ui_field(
        tr(model.lang, "Machine id override", "机器 ID 覆盖"),
        project.machine_id,
        fn(value) { ProjectMachine(value) },
        tr(model.lang, "machine id (blank = local)", "机器 ID（留空 = 本地）"),
        300.0,
      ),
    )
  }
  let project_controls : Array[@moui.View[Msg]] = [
    ui_advanced_control(model.lang, project.advanced, ProjectAdvanced(!project.advanced)),
    ui_meta(
      tr(
        model.lang,
        "Choose a machine by name; local is the default.",
        "按名称选择机器；默认为本地机器。",
      ),
    ),
    spacer(weight=1.0),
  ]
  open_form.push(
    row(project_controls, spacing=10.0, align=@style.CrossAlign::Center).frame(
      width=960.0,
    ),
  )
  if project.machine_id != "" {
    open_form.push(
      ui_id_meta(
        model.lang,
        tr(model.lang, "Machine ID", "机器 ID"),
        project.machine_id,
      ),
    )
  }
  if project.message != "" {
    open_form.push(ui_muted_wrapped(project.message, 960.0))
  }
  let open_count = project.workspaces.length().to_string() +
    tr(model.lang, " open", " 个打开")
  let workspaces : Array[@moui.View[Msg]] = [
    row([
      ui_section(tr(model.lang, "Open workspaces", "打开的工作区")),
      spacer(weight=1.0),
      ui_meta(open_count),
    ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if project.workspaces.is_empty() {
    workspaces.push(
      ui_muted_wrapped(
        if project.workspaces_loaded {
          tr(model.lang, "no open workspaces yet", "尚无打开的工作区")
        } else {
          tr(
            model.lang,
            "loading workspaces from the host...",
            "正在从主机加载工作区...",
          )
        },
        960.0,
      ),
    )
  } else {
    for record in project.workspaces {
      workspaces.push(workspace_row(model, record))
    }
  }
  column([
    ui_card(open_form, width=992.0),
    column(workspaces, spacing=10.0),
    column(project_detail(model), spacing=16.0),
  ], spacing=16.0)
}

///|
// MARK: - Agents

fn agents_page(model : Model) -> @moui.View[Msg] {
  let agent = model.agent
  let start : Array[@moui.View[Msg]] = [
    ui_page_title(tr(model.lang, "Agents / Sessions", "智能体 / 会话")),
    ui_section(tr(model.lang, "Session setup", "会话设置")),
  ]
  if agent.sessions.is_empty() {
    start.push(
      ui_muted_wrapped(
        tr(
          model.lang,
          "No agent sessions yet. Choose an agent and workspace below, then start a session.",
          "尚无智能体会话。请在下方选择智能体和工作区，然后启动会话。",
        ),
        960.0,
      ),
    )
  }
  start.push(
    row([
      ui_select_field(
        tr(model.lang, "Agent", "智能体"),
        agent_menu_items(model),
        agent.agent_id,
        agent.agent_picker_open,
        AgentToggle,
        tr(model.lang, "Select an agent", "选择智能体"),
        250.0,
      ),
      ui_select_field(
        tr(model.lang, "Workspace", "工作区"),
        workspace_menu_items(model, fn(value) { AgentWorkspaceSelect(value) }),
        agent.workspace_id,
        agent.workspace_picker_open,
        AgentWorkspaceToggle,
        tr(model.lang, "Select a workspace", "选择工作区"),
        330.0,
      ),
      column([
        ui_field_label(tr(model.lang, "Mode", "模式")),
        row([
          ui_choice_segment(
            "ACP",
            agent.mode == @contracts.AGENT_MODE_ACP,
            AgentMode(@contracts.AGENT_MODE_ACP),
          ),
          ui_choice_segment(
            "Stdout",
            agent.mode == @contracts.AGENT_MODE_STDOUT,
            AgentMode(@contracts.AGENT_MODE_STDOUT),
          ),
        ], spacing=8.0, align=@style.CrossAlign::Center),
      ], spacing=5.0, align=@style.CrossAlign::Start),
    ], spacing=12.0, align=@style.CrossAlign::End).frame(width=960.0),
  )
  if model.project.workspaces_loaded && model.project.workspaces.is_empty() {
    start.push(
      row([
        ui_muted_wrapped(
          tr(
            model.lang,
            "No workspaces are open. Open a project to select a workspace here, or start in the host's default folder.",
            "尚无打开的工作区。打开一个项目后可在此选择工作区，或从主机默认目录启动。",
          ),
          650.0,
        ),
        ui_ghost(tr(model.lang, "Open a Project", "打开项目"), SelectPage(Projects)),
        spacer(weight=1.0),
      ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
    )
  } else if !model.project.workspaces_loaded {
    start.push(
      ui_muted_wrapped(
        tr(
          model.lang,
          "Loading workspaces from the host...",
          "正在从主机加载工作区...",
        ),
        960.0,
      ),
    )
  } else if agent.workspace_id == "" {
    start.push(
      ui_meta(
        tr(
          model.lang,
          "No workspace selected; the host working directory will be used.",
          "未选择工作区；将使用主机当前工作目录。",
        ),
      ),
    )
  }
  if agent.sessions.is_empty() {
    start.push(
      row([
        ui_ghost(tr(model.lang, "Use default agent", "使用默认智能体"), AgentUseDefault),
        ui_meta(
          tr(
            model.lang,
            "There is no saved agent catalog yet; the default agent is created on first start.",
            "尚无已保存的智能体目录；默认智能体将在首次启动时创建。",
          ),
        ),
        spacer(weight=1.0),
      ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
    )
  }
  start.push(
    ui_text_area_field(
      tr(model.lang, "Initial prompt", "初始提示词"),
      agent.prompt,
      fn(value) { AgentPromptDraft(value) },
      tr(model.lang, "initial prompt", "初始提示词"),
      960.0,
      3,
    ),
  )
  start.push(
    row([
      ui_primary(tr(model.lang, "Start session", "启动会话"), AgentStartSession),
      ui_ghost(tr(model.lang, "Stop", "停止"), AgentStopSession),
      ui_ghost(tr(model.lang, "Resume", "恢复"), AgentResumeSession),
      ui_ghost(tr(model.lang, "Probe", "探测"), AgentProbeNow),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
  )
  let setup_controls : Array[@moui.View[Msg]] = [
    ui_advanced_control(model.lang, agent.advanced, AgentAdvanced(!agent.advanced)),
    ui_meta(
      tr(
        model.lang,
        "Names come from host projections. Raw ids stay optional.",
        "名称来自主机投影。原始 ID 为可选项。",
      ),
    ),
    spacer(weight=1.0),
  ]
  start.push(
    row(setup_controls, spacing=10.0, align=@style.CrossAlign::Center).frame(
      width=960.0,
    ),
  )
  if agent.advanced {
    start.push(
      row([
        ui_field(
          tr(model.lang, "Agent id override", "智能体 ID 覆盖"),
          agent.agent_id,
          fn(value) { AgentId(value) },
          "default",
          250.0,
        ),
        ui_field(
          tr(model.lang, "Workspace id override", "工作区 ID 覆盖"),
          agent.workspace_id,
          fn(value) { AgentWorkspace(value) },
          tr(model.lang, "workspace id (optional)", "工作区 ID（可选）"),
          300.0,
        ),
        ui_field(
          tr(model.lang, "Worktree id (optional)", "工作树 ID（可选）"),
          agent.worktree_id,
          fn(value) { AgentWorktree(value) },
          tr(model.lang, "worktree id (optional)", "工作树 ID（可选）"),
          250.0,
        ),
      ], spacing=12.0, align=@style.CrossAlign::End),
    )
  }
  start.push(ui_id_meta(model.lang, tr(model.lang, "Agent ID", "智能体 ID"), agent.agent_id))
  if agent.workspace_id != "" {
    start.push(
      ui_id_meta(
        model.lang,
        tr(model.lang, "Workspace ID", "工作区 ID"),
        agent.workspace_id,
      ),
    )
  }
  if agent.worktree_id != "" {
    start.push(
      ui_id_meta(
        model.lang,
        tr(model.lang, "Worktree ID", "工作树 ID"),
        agent.worktree_id,
      ),
    )
  }
  if agent.message != "" {
    start.push(ui_muted_wrapped(agent.message, 960.0))
  }
  let session : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Session", "会话")),
  ]
  if !agent.sessions.is_empty() {
    let selected_session = match agent.session {
      Some(record) => record.id
      None => ""
    }
    session.push(
      ui_select_field(
        tr(model.lang, "Recent session", "最近会话"),
        session_menu_items(model),
        selected_session,
        agent.session_picker_open,
        AgentSessionToggle,
        tr(model.lang, "Select a recent session", "选择最近会话"),
        440.0,
      ),
    )
  }
  match agent.session {
    Some(record) => {
      let state = if agent.state_text == "" { record.state } else { agent.state_text }
      session.push(
        row([
          ui_tag(state),
          ui_meta(
            tr(model.lang, "turns ", "轮次 ") +
            record.turns.to_string() +
            tr(model.lang, " · chunks ", " · 片段 ") +
            record.chunks.to_string() +
            tr(model.lang, " · memory ", " · 内存 ") +
            record.memory_bytes.to_string() +
            tr(model.lang, "B · artifacts ", "B · 产物 ") +
            record.artifacts.length().to_string() +
            (if agent.stop_reason == "" {
              ""
            } else {
              tr(model.lang, " · stop ", " · 停止原因 ") + agent.stop_reason
            }),
          ),
          spacer(weight=1.0),
        ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
      )
      session.push(ui_id_meta(model.lang, tr(model.lang, "Session ID", "会话 ID"), record.id))
    }
    None =>
      session.push(
        ui_muted_wrapped(
          tr(
            model.lang,
            "No session selected. Start one above or open a recent session.",
            "尚未选择会话。请在上方启动会话或打开最近会话。",
          ),
          960.0,
        ),
      )
  }
  if agent.pending_decision != "" {
    session.push(
      text(
        tr(model.lang, "pending decision: ", "待处理决策：") +
        agent.pending_decision,
        width=960.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(mono_font(11.0, 400)).foreground(ui_warning()),
    )
  }
  let transcript : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Transcript", "对话记录")),
    ui_code_block(
      if agent.transcript == "" {
        tr(model.lang, "No session yet", "暂无会话")
      } else {
        agent.transcript
      },
      960.0,
      height=220.0,
      size=12.0,
    ),
    ui_text_area_field(
      tr(model.lang, "Follow-up prompt", "后续提示词"),
      agent.input,
      fn(value) { AgentInputDraft(value) },
      tr(
        model.lang,
        "write a follow-up; multiple lines are supported",
        "输入后续提示词；支持多行",
      ),
      960.0,
      3,
    ),
    row([
      ui_primary(tr(model.lang, "Send", "发送"), AgentSendInput),
      ui_ghost(tr(model.lang, "Stop", "停止"), AgentStopSession),
      ui_ghost(tr(model.lang, "Resume", "恢复"), AgentResumeSession),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  let recent : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Recent sessions", "最近会话")),
  ]
  if agent.sessions.is_empty() {
    recent.push(
      ui_muted_wrapped(
        tr(
          model.lang,
          "No agent sessions yet. Start the default agent above to create the first one.",
          "尚无智能体会话。请在上方启动默认智能体以创建第一个会话。",
        ),
        960.0,
      ),
    )
  } else {
    let mut index = 1
    for record in agent.sessions {
      let agent_label = if record.agent_id == "" {
        tr(model.lang, "(no agent)", "（无智能体）")
      } else {
        agent_name_for(model, record.agent_id)
      }
      recent.push(
        column([
          row([
            ui_row_title_wrapped(
              tr(model.lang, "Session ", "会话 ") +
              index.to_string() +
              " · " +
              record.state,
              620.0,
            ),
            ui_tag(record.state),
            spacer(weight=1.0),
            ui_ghost_small(
              tr(model.lang, "Open", "打开"),
              AgentSelectSession(record.id),
            ),
            ui_ghost_small(
              tr(model.lang, "Copy ID", "复制 ID"),
              CopyId(tr(model.lang, "Session ID", "会话 ID"), record.id),
            ),
          ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
          ui_meta(
            agent_label +
            " · " +
            workspace_name_for(model, record.workspace_id) +
            tr(model.lang, " · turns ", " · 轮次 ") +
            record.turns.to_string() +
            " · " +
            record.cwd,
          ),
          ui_mono(record.id, 10.5),
        ], spacing=4.0, align=@style.CrossAlign::Start).frame(width=960.0),
      )
      recent.push(ui_divider_soft())
      index = index + 1
    }
  }
  column([
    ui_card(start, width=992.0),
    ui_card(session, width=992.0),
    ui_card(transcript, width=992.0),
    ui_card(recent, width=992.0),
  ], spacing=16.0)
}

///|
// MARK: - Inbox

fn inbox_decision_card(
  model : Model,
  decision : @contracts.DecisionRecord,
) -> @moui.View[Msg] {
  let bucket = inbox_bucket_of(decision)
  let actionable = bucket == @contracts.INBOX_NEEDS_YOU
  let meta =
    tr(model.lang, "session ", "会话 ") +
    (if decision.session_id == "" {
      tr(model.lang, "(none)", "（无）")
    } else {
      decision.session_id
    }) +
    tr(model.lang, " · agent ", " · 智能体 ") +
    decision.agent_id +
    (if decision.run_id == "" {
      ""
    } else {
      tr(model.lang, " · run ", " · 运行 ") + decision.run_id
    })
  let body : Array[@moui.View[Msg]] = [
    row([
      ui_dot(status_tone(bucket)),
      ui_mono(decision.kind.to_upper(), 10.0),
      ui_tag(decision.status),
      ui_tag(bucket),
      spacer(weight=1.0),
      ui_mono(
        if decision.run_id == "" { "" } else { decision.run_id },
        10.5,
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=964.0),
    text(
      decision.title,
      width=964.0,
      align=@core.TextAlign::TextStart,
      wrap=true,
    ).font(ui_font(15.0, 600)).foreground(ui_text_color()),
    text(meta, width=964.0, align=@core.TextAlign::TextStart, wrap=true)
    .font(mono_font(11.0, 400))
    .foreground(ui_dim()),
  ]
  if decision.detail == "" {
    body.push(ui_meta(tr(model.lang, "(no detail)", "（无详情）")))
  } else {
    body.push(ui_code_block(decision.detail, 964.0))
  }
  let answers : Array[@moui.View[Msg]] = []
  if actionable {
    for option in decision.options {
      answers.push(
        ui_ghost_small(
          option.name,
          InboxAnswer(decision.id, option.option_id),
        ),
      )
    }
    answers.push(
      ui_ghost_small(
        tr(model.lang, "Answer with text", "用文本回答"),
        InboxSubmitText(decision.id),
      ),
    )
  }
  if answers.is_empty() {
    body.push(ui_meta(tr(model.lang, "handled", "已处理")))
  } else {
    body.push(row(answers, spacing=8.0, align=@style.CrossAlign::Center))
  }
  if decision.status == @contracts.DECISION_STATUS_ANSWERED {
    body.push(
      ui_meta(
        tr(model.lang, "answered by ", "回答者：") +
        (if decision.answered_by == "" {
          tr(model.lang, "owner", "所有者")
        } else {
          decision.answered_by
        }) +
        (if decision.option_id == "" { "" } else { " · " + decision.option_id }) +
        (if decision.answer_text == "" { "" } else { " · " + decision.answer_text }),
      ),
    )
  }
  let filled = container(
    padding(column(body, spacing=8.0).frame(width=964.0), 14.0),
    width=992.0,
    background=ui_surface(),
    corner_radius=10.0,
    border=Some(ui_edge(ui_border_soft())),
    padding=0.0,
  )
  filled
}

///|
fn push_inbox_section(
  model : Model,
  lines : Array[@moui.View[Msg]],
  title : String,
  items : Array[@contracts.DecisionRecord],
) -> Unit {
  if items.length() == 0 {
    return
  }
  lines.push(ui_section(title))
  for decision in items {
    lines.push(inbox_decision_card(model, decision))
  }
}

///|
fn inbox_page(model : Model) -> @moui.View[Msg] {
  let inbox = model.inbox
  let needs : Array[@contracts.DecisionRecord] = []
  let waiting : Array[@contracts.DecisionRecord] = []
  let handled : Array[@contracts.DecisionRecord] = []
  for decision in inbox.decisions {
    let bucket = inbox_bucket_of(decision)
    if bucket == @contracts.INBOX_NEEDS_YOU {
      needs.push(decision)
    } else if bucket == @contracts.INBOX_WAITING {
      waiting.push(decision)
    } else {
      handled.push(decision)
    }
  }
  let needs_title = tr(model.lang, "Needs you", "需要你")
  let waiting_title = tr(model.lang, "Waiting", "等待中")
  let handled_title = tr(model.lang, "Handled", "已处理")
  let stats = row([
    ui_stat_card(
      needs_title,
      needs.length().to_string(),
      tr(model.lang, "waiting on you", "等待你处理"),
      322.0,
    ),
    ui_stat_card(
      waiting_title,
      waiting.length().to_string(),
      tr(model.lang, "in flight", "处理中"),
      322.0,
    ),
    ui_stat_card(
      handled_title,
      handled.length().to_string(),
      tr(model.lang, "resolved", "已解决"),
      322.0,
    ),
  ], spacing=12.0).frame(width=992.0)
  let lines : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Approvals", "审批")),
    ui_muted_wrapped(
      tr(
        model.lang,
        "Approvals, Agent permissions, evidence-gate waivers and recovery retries all wait in this one queue. An answer is recorded as an event and an audit record; nothing is auto-approved.",
        "审批、智能体权限、证据门禁豁免和恢复重试都汇聚在这一队列。回答会记录为事件和审计记录；不会自动批准任何事项。",
      ),
      960.0,
    ),
  ]
  // `inbox.message` carries the same needs/waiting/handled counts already shown
  // in the stat cards above, so only surface transient status text here.
  let counts_prefix = tr(model.lang, "needs you: ", "需要你：")
  if inbox.message != "" && !inbox.message.has_prefix(counts_prefix) {
    lines.push(ui_meta(inbox.message))
  }
  let queue : Array[@moui.View[Msg]] = []
  if inbox.decisions.is_empty() {
    queue.push(
      ui_muted_wrapped(tr(model.lang, "No decisions yet.", "暂无决策。"), 960.0),
    )
  } else {
    push_inbox_section(model, queue, needs_title, needs)
    push_inbox_section(model, queue, waiting_title, waiting)
    push_inbox_section(model, queue, handled_title, handled)
  }
  column([
    stats,
    ui_card(lines, width=992.0),
    column(queue, spacing=10.0),
    ui_card([
      ui_section(tr(model.lang, "Answer text", "回答文本")),
      row([
        ui_field(
          tr(model.lang, "Free text", "自由文本"),
          inbox.text,
          fn(value) { InboxText(value) },
          tr(
            model.lang,
            "free-text answer (questions/readiness)",
            "自由文本回答（问题/就绪度）",
          ),
          760.0,
        ),
        spacer(weight=1.0),
      ], spacing=12.0, align=@style.CrossAlign::End).frame(width=960.0),
    ], width=992.0),
  ], spacing=16.0)
}

///|
// MARK: - Tasks

fn task_card(
  model : Model,
  record : @contracts.TaskRecord,
) -> @moui.View[Msg] {
  let selected = model.task.selected_task == record.id
  let meta =
    tr(model.lang, "workspace ", "工作区 ") +
    workspace_name_for(model, record.workspace_id) +
    (if record.parent_id == "" {
      ""
    } else {
      tr(model.lang, " · parent ", " · 父任务 ") +
      task_title_for(model, record.parent_id)
    }) +
    tr(model.lang, " · verify ", " · 验证 ") +
    record.verify.length().to_string() +
    (if record.goal == "" { "" } else { " · " + record.goal })
  let child = column([
    row([
      ui_row_title_wrapped(record.title, 500.0),
      ui_tag(record.status),
      spacer(weight=1.0),
      ui_ghost_small(tr(model.lang, "Select", "选择"), TaskSelect(record.id)),
      ui_ghost_small(
        tr(model.lang, "Cancel", "取消"),
        TaskCancelNow(record.id),
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=964.0),
    row([
      ui_mono_wrapped(meta, 10.5, 720.0, ui_dim()),
      spacer(weight=1.0),
      ui_mono(record.id, 10.5),
      ui_ghost_small(
        tr(model.lang, "Copy ID", "复制 ID"),
        CopyId(tr(model.lang, "Task ID", "任务 ID"), record.id),
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=964.0),
  ], spacing=6.0).frame(width=964.0)
  container(
    padding(column([child], spacing=0.0), 14.0),
    width=992.0,
    background=if selected { ui_accent_soft() } else { ui_surface() },
    corner_radius=10.0,
    border=Some(
      ui_edge(
        if selected {
          ui_accent().multiply_alpha(0.45)
        } else {
          ui_border_soft()
        },
      ),
    ),
    padding=0.0,
  )
}

///|
fn run_row(
  model : Model,
  record : @contracts.RunRecord,
) -> @moui.View[Msg] {
  let origin =
    machine_name_for(model, record.machine_id) +
    (if record.worktree_id == "" {
      ""
    } else {
      tr(model.lang, " · worktree", " · 工作树")
    }) +
    (if record.worktree_id == "" {
      ""
    } else {
      " · " + record.worktree_id
    })
  column([
    row([
      text(
        record.mode + ": " + record.command,
        width=560.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(mono_font(11.0, 400)).foreground(ui_text_color()),
      ui_tag(record.status),
      spacer(weight=1.0),
      ui_ghost_small(tr(model.lang, "Open", "打开"), RunSelect(record.id)),
      ui_ghost_small(
        tr(model.lang, "Cancel", "取消"),
        RunCancelNow(record.id),
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
    row([
      ui_mono_wrapped(origin, 10.5, 700.0, ui_dim()),
      spacer(weight=1.0),
      ui_mono(record.id, 10.5),
      ui_ghost_small(
        tr(model.lang, "Copy ID", "复制 ID"),
        CopyId(tr(model.lang, "Run ID", "运行 ID"), record.id),
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ], spacing=4.0)
}

///|
fn run_detail_view(model : Model) -> @moui.View[Msg] {
  let children : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Run detail", "运行详情")),
  ]
  match model.task.detail {
    Some(detail) => {
      let run = detail.run
      children.push(
        row([
          text(
            tr(model.lang, "Run result", "运行结果"),
            align=@core.TextAlign::TextStart,
          ).font(ui_font(14.0, 600)).foreground(ui_text_color()),
          ui_tag(run.status),
          spacer(weight=1.0),
          ui_ghost_small(
            tr(model.lang, "Copy ID", "复制 ID"),
            CopyId(tr(model.lang, "Run ID", "运行 ID"), run.id),
          ),
        ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
      )
      children.push(
        ui_mono(
          machine_name_for(model, run.machine_id) +
          " · " +
          run.mode +
          (if run.worktree_id == "" {
            ""
          } else {
            tr(model.lang, " · worktree ", " · 工作树 ") + run.worktree_id
          }),
          10.5,
        ),
      )
      children.push(ui_id_meta(model.lang, tr(model.lang, "Run ID", "运行 ID"), run.id))
      children.push(
        ui_code_block(
          (if run.command == "" { run.prompt } else { run.command }) +
          (if run.stop_reason == "" {
            ""
          } else {
            tr(model.lang, "\nstop: ", "\n停止：") + run.stop_reason
          }) +
          (if run.last_error == "" {
            ""
          } else {
            tr(model.lang, "\nerror: ", "\n错误：") + run.last_error
          }) +
          (if run.output_summary == "" {
            ""
          } else {
            tr(model.lang, "\nsummary: ", "\n摘要：") + run.output_summary
          }),
          960.0,
        ),
      )
      children.push(ui_section(tr(model.lang, "Evidence", "证据")))
      if detail.evidence.is_empty() {
        children.push(
          ui_muted_wrapped(tr(model.lang, "(no evidence yet)", "（暂无证据）"), 900.0),
        )
      } else {
        for evidence in detail.evidence {
          let evidence_body : Array[@moui.View[Msg]] = [
            row([
              text(evidence.name + " · " + evidence.kind, align=@core.TextAlign::TextStart).font(ui_font(13.0, 600)).foreground(ui_text_color()),
              spacer(weight=1.0),
              ui_tag(
                if evidence.passed {
                  tr(model.lang, "passed", "通过")
                } else if evidence.waived {
                  tr(model.lang, "waived", "已豁免")
                } else {
                  tr(model.lang, "failed", "失败")
                },
              ),
            ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=912.0),
            ui_mono(
              "$ " +
              evidence.command +
              tr(model.lang, " · exit ", " · 退出码 ") +
              evidence.exit_code.to_string(),
              10.5,
            ),
          ]
          evidence_body.push(
            ui_code_block(
              if evidence.excerpt == "" {
                tr(model.lang, "(no output)", "（无输出）")
              } else {
                evidence.excerpt
              },
              912.0,
            ),
          )
          if evidence.artifact_id == "" {
            evidence_body.push(ui_meta(tr(model.lang, "no artifact", "无产物")))
          } else {
            evidence_body.push(
              row([
                ui_mono(
                  tr(model.lang, "artifact ", "产物 ") + evidence.artifact_id,
                  10.5,
                ),
                spacer(weight=1.0),
                ui_ghost_small(
                  tr(model.lang, "Read", "读取"),
                  ArtifactReadNow(evidence.artifact_id),
                ),
              ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=912.0),
            )
          }
          children.push(ui_card(evidence_body, padding=12.0, width=936.0))
        }
      }
      children.push(ui_section(tr(model.lang, "Artifacts", "产物")))
      if detail.artifacts.is_empty() {
        children.push(
          ui_muted_wrapped(tr(model.lang, "(no artifacts)", "（暂无产物）"), 900.0),
        )
      } else {
        for artifact in detail.artifacts {
          children.push(
            row([
              text(
                artifact.kind +
                " · " +
                artifact.size.to_string() +
                "B · " +
                artifact.uri,
                width=760.0,
                align=@core.TextAlign::TextStart,
                wrap=true,
              ).font(mono_font(10.5, 400)).foreground(ui_dim()),
              spacer(weight=1.0),
              ui_ghost_small(tr(model.lang, "Read", "读取"), ArtifactReadNow(artifact.id)),
            ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
          )
        }
      }
      if model.task.artifact_text != "" {
        children.push(
          ui_section(
            tr(model.lang, "Artifact: ", "产物：") + model.task.artifact_name,
          ),
        )
        children.push(ui_code_block(model.task.artifact_text, 960.0))
      }
      children.push(ui_section(tr(model.lang, "Diff (HEAD)", "差异（HEAD）")))
      if detail.diff == "" {
        children.push(
          ui_muted_wrapped(
            tr(
              model.lang,
              "(no diff / not a git worktree)",
              "（无差异 / 不是 git 工作树）",
            ),
            900.0,
          ),
        )
      } else {
        children.push(ui_code_block(detail.diff, 960.0))
      }
    }
    None =>
      children.push(
        ui_muted_wrapped(
          tr(
            model.lang,
            "Select a run to inspect evidence, artifacts and the diff.",
            "选择一个运行以查看证据、产物和差异。",
          ),
          900.0,
        ),
      )
  }
  ui_card(children, width=992.0)
}

///|
fn activity_view(model : Model) -> @moui.View[Msg] {
  let events = model.task.events
  let children : Array[@moui.View[Msg]] = [
    row([
      ui_section(tr(model.lang, "Activity", "活动")),
      spacer(weight=1.0),
      ui_meta(
        tr(model.lang, "cursor ", "游标 ") +
        model.task.event_seq.to_string() +
        " · " +
        events.length().to_string() +
        tr(model.lang, " cached", " 已缓存"),
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if events.is_empty() {
    children.push(
      ui_muted_wrapped(tr(model.lang, "(no events yet)", "（暂无事件）"), 900.0),
    )
  } else {
    let start = if events.length() > 30 { events.length() - 30 } else { 0 }
    let mut index = start
    while index < events.length() {
      let event = events[index]
      children.push(
        container(
          padding_xy(
            text(
              "#" +
              event.seq.to_string() +
              " " +
              event.event_type +
              " · " +
              event.subject,
              width=900.0,
              align=@core.TextAlign::TextStart,
              wrap=false,
            ).font(mono_font(10.5, 400)).foreground(ui_dim()),
            horizontal=0.0,
          ),
          height=26.0,
          padding=0.0,
        ),
      )
      index = index + 1
    }
  }
  ui_card(children, width=992.0)
}

///|
fn tasks_page(model : Model) -> @moui.View[Msg] {
  let state = model.task
  let create : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Create task", "创建任务")),
    row([
      ui_field(
        tr(model.lang, "Title", "标题"),
        state.title,
        fn(value) { TaskTitle(value) },
        tr(model.lang, "task title (required)", "任务标题（必填）"),
        440.0,
      ),
      ui_select_field(
        tr(model.lang, "Workspace", "工作区"),
        workspace_menu_items(model, fn(value) { TaskWorkspaceSelect(value) }),
        state.workspace_id,
        state.workspace_picker_open,
        TaskWorkspaceToggle,
        tr(model.lang, "Select a workspace", "选择工作区"),
        360.0,
      ),
    ], spacing=12.0, align=@style.CrossAlign::End),
    ui_field(
      tr(model.lang, "Goal", "目标"),
      state.goal,
      fn(value) { TaskGoal(value) },
      tr(model.lang, "goal (optional)", "目标（可选）"),
      560.0,
    ),
    ui_text_area_field(
      tr(model.lang, "Verify commands", "验证命令"),
      state.verify_text,
      fn(value) { TaskVerify(value) },
      tr(model.lang, "verify commands, one per line", "验证命令，每行一条"),
      960.0,
      3,
    ),
  ]
  if model.project.workspaces_loaded && model.project.workspaces.is_empty() {
    create.push(
      row([
        ui_muted_wrapped(
          tr(
            model.lang,
            "No workspaces are open. Open a Project to select one here.",
            "尚无打开的工作区。打开一个项目后可在此选择工作区。",
          ),
          650.0,
        ),
        ui_ghost(tr(model.lang, "Open a Project", "打开项目"), SelectPage(Projects)),
        spacer(weight=1.0),
      ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
    )
  } else if !model.project.workspaces_loaded {
    create.push(
      ui_muted_wrapped(
        tr(
          model.lang,
          "Loading workspaces from the host...",
          "正在从主机加载工作区...",
        ),
        960.0,
      ),
    )
  } else {
    create.push(
      ui_meta(
        tr(
          model.lang,
          "The most recent workspace is selected by default.",
          "默认选择最近使用的工作区。",
        ),
      ),
    )
  }
  create.push(
    row([
      ui_advanced_control(model.lang, state.advanced, TaskAdvanced(!state.advanced)),
      ui_meta(
        tr(
          model.lang,
          "Names come from host projections. Raw ids stay optional.",
          "名称来自主机投影。原始 ID 为可选项。",
        ),
      ),
      spacer(weight=1.0),
    ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
  )
  if state.advanced {
    create.push(
      ui_field(
        tr(model.lang, "Workspace id override", "工作区 ID 覆盖"),
        state.workspace_id,
        fn(value) { TaskWorkspace(value) },
        tr(model.lang, "workspace id", "工作区 ID"),
        360.0,
      ),
    )
  }
  if state.workspace_id != "" {
    create.push(
      ui_id_meta(
        model.lang,
        tr(model.lang, "Workspace ID", "工作区 ID"),
        state.workspace_id,
      ),
    )
  }
  create.push(
    row([
      ui_primary(tr(model.lang, "Create", "创建"), TaskCreateSubmit),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center),
  )
  if state.message != "" {
    create.push(ui_muted_wrapped(state.message, 960.0))
  }
  let board : Array[@moui.View[Msg]] = [
    row([
      ui_section(tr(model.lang, "Board", "看板")),
      spacer(weight=1.0),
      ui_meta(
        state.tasks.length().to_string() +
        (if state.tasks.length() == 1 {
          tr(model.lang, " task", " 个任务")
        } else {
          tr(model.lang, " tasks", " 个任务")
        }),
      ),
    ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if state.tasks.is_empty() {
    board.push(
      ui_muted_wrapped(tr(model.lang, "No tasks yet.", "暂无任务。"), 960.0),
    )
  } else {
    for record in state.tasks {
      board.push(task_card(model, record))
    }
  }
  if state.selected_task != "" {
    let runs : Array[@moui.View[Msg]] = [
      row([
        ui_section(
          tr(model.lang, "Runs for ", "运行列表：") +
          task_title_for(model, state.selected_task),
        ),
        spacer(weight=1.0),
        ui_meta(
          state.runs.length().to_string() +
          (if state.runs.length() == 1 {
            tr(model.lang, " run", " 个运行")
          } else {
            tr(model.lang, " runs", " 个运行")
          }),
        ),
      ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
    ]
    runs.push(
      ui_id_meta(
        model.lang,
        tr(model.lang, "Task ID", "任务 ID"),
        state.selected_task,
      ),
    )
    if state.runs.is_empty() {
      runs.push(
        ui_muted_wrapped(tr(model.lang, "(no runs yet)", "（暂无运行）"), 900.0),
      )
    } else {
      for record in state.runs {
        runs.push(run_row(model, record))
      }
    }
    runs.push(
      row([
        ui_field(
          tr(model.lang, "Command", "命令"),
          state.command,
          fn(value) { TaskCommand(value) },
          tr(model.lang, "command to run in the worktree", "在工作树中运行的命令"),
          520.0,
        ),
        ui_select_field(
          tr(model.lang, "Machine", "机器"),
          machine_menu_items(model, fn(value) { TaskMachineSelect(value) }),
          state.machine_id,
          state.machine_picker_open,
          TaskMachineToggle,
          tr(model.lang, "Select a machine", "选择机器"),
          240.0,
        ),
        ui_primary(tr(model.lang, "Dispatch run", "派发运行"), RunDispatch),
      ], spacing=12.0, align=@style.CrossAlign::End),
    )
    if state.advanced {
      runs.push(
        ui_field(
          tr(model.lang, "Machine id override", "机器 ID 覆盖"),
          state.machine_id,
          fn(value) { TaskMachine(value) },
          tr(model.lang, "machine id (blank = local)", "机器 ID（留空 = 本地）"),
          300.0,
        ),
      )
    }
    if state.machine_id != "" {
      runs.push(
        ui_id_meta(
          model.lang,
          tr(model.lang, "Machine ID", "机器 ID"),
          state.machine_id,
        ),
      )
    } else {
      runs.push(
        ui_meta(
          tr(
            model.lang,
            "Local machine is the default.",
            "默认使用本地机器。",
          ),
        ),
      )
    }
    board.push(ui_card(runs, width=992.0))
  }
  column([
    ui_card(create, width=992.0),
    column(board, spacing=10.0),
    run_detail_view(model),
    activity_view(model),
  ], spacing=16.0)
}

///|
// MARK: - Search

fn search_page(model : Model) -> @moui.View[Msg] {
  let state = model.search
  let form : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Search sessions", "搜索会话")),
    row([
      ui_field(
        tr(model.lang, "Query", "查询"),
        state.query,
        fn(value) { SearchQuery(value) },
        tr(
          model.lang,
          "e.g. verify failed, flaky test, waived",
          "例如：验证失败、偶发测试、已豁免",
        ),
        760.0,
      ),
      ui_primary(tr(model.lang, "Search", "搜索"), SearchSubmit),
    ], spacing=12.0, align=@style.CrossAlign::End),
    ui_meta(
      tr(
        model.lang,
        "Search session transcripts and decision text recorded by the host.",
        "搜索主机记录的会话对话和决策文本。",
      ),
    ),
    ui_meta(
      if state.backend == "" {
        tr(
          model.lang,
          "FTS5 when available, LIKE otherwise",
          "可用时使用 FTS5，否则使用 LIKE",
        )
      } else {
        tr(model.lang, "backend: ", "后端：") + state.backend
      },
    ),
  ]
  if state.message != "" {
    form.push(ui_muted_wrapped(state.message, 960.0))
  }
  let results : Array[@moui.View[Msg]] = []
  if state.hits.is_empty() {
    results.push(
      ui_card([
        ui_muted_wrapped(
          tr(
            model.lang,
            "No hits yet. Search matches session transcripts and decision text.",
            "暂无结果。搜索会匹配会话对话和决策文本。",
          ),
          960.0,
        ),
      ], width=992.0),
    )
  } else {
    for hit in state.hits {
      results.push(
        ui_card([
          row([
            ui_tag(hit.kind),
            text(hit.title, width=700.0, align=@core.TextAlign::TextStart, wrap=true)
            .font(ui_font(14.0, 600)).foreground(ui_text_color()),
            spacer(weight=1.0),
            ui_mono(hit.ref_id, 10.5),
          ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
          ui_code_block(hit.snippet, 960.0),
          ui_meta(hit.ts),
        ], width=992.0),
      )
    }
  }
  column([
    ui_card(form, width=992.0),
    column(results, spacing=10.0),
  ], spacing=16.0)
}

///|
// MARK: - Settings

fn settings_page(model : Model) -> @moui.View[Msg] {
  let host = model.host
  let connection : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Connection", "连接")),
    ui_mono(
      tr(model.lang, "state: ", "状态：") + host.link.label_in(model.lang),
      11.0,
    ),
    ui_mono(
      tr(model.lang, "host address: ", "主机地址：") +
      (if host.ws_url == "" {
        tr(model.lang, "(waiting for host.json)", "（等待 host.json）")
      } else {
        host.ws_url
      }),
      11.0,
    ),
    ui_mono(
      tr(model.lang, "token: ", "令牌：") +
      token_status_text_in(host.token_status, model.lang),
      11.0,
    ),
    ui_mono(
      tr(model.lang, "version: ", "版本：") +
      (if host.version == "" {
        tr(model.lang, "(not connected)", "（未连接）")
      } else {
        host.version
      }),
      11.0,
    ),
    ui_mono(
      tr(model.lang, "data directory: ", "数据目录：") + host.state_dir,
      11.0,
    ),
    ui_mono(
      tr(model.lang, "host id: ", "主机 ID：") +
      (if host.host_id == "" {
        tr(model.lang, "(not connected)", "（未连接）")
      } else {
        host.host_id
      }),
      11.0,
    ),
  ]
  if host.last_error != "" {
    connection.push(
      text(
        tr(model.lang, "last error: ", "最后错误：") + host.last_error,
        width=960.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(11.0, 400)).foreground(ui_danger()),
    )
  }
  let appearance : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Appearance", "外观")),
    row([
      ui_segment(tr(model.lang, "Light", "浅色"), Light, model.theme_mode),
      ui_segment(tr(model.lang, "Dark", "深色"), Dark, model.theme_mode),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center),
    ui_meta(
      tr(
        model.lang,
        "Applies immediately and is saved for future launches; MONEXUS_THEME picks the startup mode only until you choose one.",
        "立即生效并保存供后续启动使用；在你做出选择前，MONEXUS_THEME 决定启动模式。",
      ),
    ),
  ]
  // A corrupt preference file or a failed write is reported here rather than
  // silently changing the user's choice.
  if model.theme_note != "" {
    appearance.push(
      text(
        model.theme_note,
        width=960.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(11.0, 400)).foreground(ui_danger()),
    )
  }
  let language : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Language", "语言")),
    row([
      ui_language_segment("English", English, model.lang),
      ui_language_segment("中文", Chinese, model.lang),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center),
    ui_meta(
      tr(
        model.lang,
        "Switches the desktop UI immediately and is saved for future launches; MONEXUS_LANG picks the startup language only until you choose one.",
        "立即切换桌面界面并保存供后续启动使用；在你做出选择前，MONEXUS_LANG 决定启动语言。",
      ),
    ),
  ]
  if model.lang_note != "" {
    language.push(
      text(
        model.lang_note,
        width=960.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(ui_font(11.0, 400)).foreground(ui_danger()),
    )
  }
  let local_host : Array[@moui.View[Msg]] = [
    ui_section(tr(model.lang, "Local host", "本地主机")),
    ui_muted_wrapped(
      tr(
        model.lang,
        "Start or reuse the host with monexus. Headless machines: monexus start --headless.",
        "用 monexus 启动或复用主机。无图形界面的机器：monexus start --headless。",
      ),
      960.0,
    ),
  ]
  column([
    ui_card(connection, width=992.0),
    ui_card(appearance, width=992.0),
    ui_card(language, width=992.0),
    ui_card(local_host, width=992.0),
  ], spacing=16.0)
}

///|
fn page_body(model : Model) -> @moui.View[Msg] {
  match model.page {
    Home => home_page(model)
    Machines => machines_page(model)
    Projects =>
      if terminal_focus_active(model) {
        terminal_page(model)
      } else {
        projects_page(model)
      }
    Agents => agents_page(model)
    Inbox => inbox_page(model)
    Tasks => tasks_page(model)
    Search => search_page(model)
    Settings => settings_page(model)
  }
}

///|
fn main_island(model : Model) -> @moui.View[Msg] {
  let body = if terminal_focus_active(model) {
    // The focused terminal owns its only scroll viewport; wrapping it in the
    // page scroll would nest two vertical scrollers.
    padding_edges(
      page_body(model),
      top=ui_body_padding,
      right=ui_body_padding,
      bottom=ui_body_padding,
      left=ui_body_padding,
    )
  } else {
    scroll_view(
      padding_edges(
        page_body(model).frame(width=ui_body_width),
        top=ui_body_padding,
        right=ui_body_padding,
        bottom=ui_body_padding,
        left=ui_body_padding,
      ),
      width=ui_main_width,
      height=ui_scroll_height,
      request=@core.ScrollRequest::new(
        id=model.scroll_epoch,
        offset=@core.Point::new(x=0.0, y=0.0),
      ),
      shows_indicator=true,
    )
  }
  let content = column([
    top_bar(model),
    ui_divider(),
    body,
    ui_divider(),
    status_bar(model),
  ], spacing=0.0).frame(width=ui_main_width, height=ui_main_height)
  ui_panel(content, width=ui_main_width, height=ui_main_height)
}

///|
pub fn view(model : Model) -> @moui.View[Msg] {
  // Repaint the whole window from the model's appearance before building any
  // child, so the hand-painted shell and MoUI controls agree on one palette.
  apply_theme_mode(model.theme_mode)
  let shell = row([
    sidebar(model),
    main_island(model),
  ], spacing=ui_gap, align=@style.CrossAlign::Start)
  container(
    shell,
    width=ui_window_width,
    height=ui_window_height,
    background=ui_frame(),
    padding=ui_margin,
  ).theme(app_theme())
}
