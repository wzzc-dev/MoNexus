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
/// Left navigation row: 32pt tall, Lucide glyph + label, accent tint when the
/// page is open and a hover wash otherwise. The Inbox row carries its needs-you
/// count.
fn nav_item(model : Model, page : Page) -> @moui.View[Msg] {
  let label = page.label()
  let active = model.page.label() == label
  let hover_key = "nav:" + label
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
  if label == "Inbox" {
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
    ui_page_title(model.page.label()),
    spacer(weight=1.0),
    ui_state_pill("host " + model.host.link.label(), link_tone(model.host.link)),
  ]
  match page_refresh_msg(model) {
    Some(msg) => children.push(ui_ghost_compact("Refresh", msg, 64.0))
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
  let left = if host.host_id == "" { "not connected" } else { host.host_id }
  let right = if host.event_count > 0 {
    "events: " +
    host.event_count.to_string() +
    " · seq " +
    host.event_seq.to_string()
  } else {
    "MoNexus " + @contracts.PRODUCT_VERSION + " · 8 pages"
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
      "Machines",
      model.machines.length().to_string(),
      if model.machines.is_empty() { "none registered" } else { "registered" },
      322.0,
    ),
    ui_stat_card(
      "Decisions",
      model.inbox.decisions.length().to_string(),
      if model.inbox.decisions.is_empty() {
        "inbox empty"
      } else {
        "in the inbox"
      },
      322.0,
    ),
    ui_stat_card(
      "Tasks",
      model.task.tasks.length().to_string(),
      if model.task.tasks.is_empty() { "board empty" } else { "on the board" },
      322.0,
    ),
  ], spacing=12.0).frame(width=992.0)
  let connection : Array[@moui.View[Msg]] = [
    ui_section("Connection"),
    ui_kv("state", host.link.label(), 960.0),
    ui_kv(
      "host id",
      if host.host_id == "" { "(not connected)" } else { host.host_id },
      960.0,
    ),
    ui_kv(
      "endpoint",
      if host.ws_url == "" {
        "(waiting for host.json)"
      } else {
        host.ws_url
      },
      960.0,
    ),
    ui_kv(
      "version",
      if host.version == "" { "(not connected)" } else { host.version },
      960.0,
    ),
    ui_kv(
      "events",
      if host.event_count == 0 {
        "none yet"
      } else {
        host.event_count.to_string() +
        " · last " +
        host.last_event +
        " @" +
        host.event_seq.to_string()
      },
      960.0,
    ),
  ]
  if host.last_error != "" {
    connection.push(
      text("reason: " + host.last_error, width=960.0, align=@core.TextAlign::TextStart, wrap=true)
      .font(ui_font(11.0, 400))
      .foreground(ui_danger()),
    )
  }
  column([
    ui_hero("Welcome to MoNexus"),
    ui_muted_wrapped(
      "A local-first desktop shell for machines, tasks and agent sessions.",
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
  let status = machine_status_text(record.status)
  let identity = if record.identity == "" { "(default)" } else { record.identity }
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
      ui_meta("identity " + identity),
      ui_meta("config " + (if record.use_ssh_config { "on" } else { "off" })),
      spacer(weight=1.0),
    ], spacing=12.0, align=@style.CrossAlign::Center).frame(width=960.0),
    ui_meta(
      "host keys " +
      record.host_key_policy +
      " · " +
      machine_profile_summary(record),
    ),
  ]
  if record.last_error != "" {
    children.push(
      text("reason: " + record.last_error, width=900.0, align=@core.TextAlign::TextStart, wrap=true)
      .font(ui_font(11.0, 400))
      .foreground(ui_danger()),
    )
  }
  let actions : Array[@moui.View[Msg]] = [
    ui_ghost_small("Probe", ProbeMachine(record.id)),
    ui_danger_ghost("Remove", RemoveMachine(record.id)),
  ]
  if model.machine_busy == record.id {
    actions.push(ui_meta("working..."))
  }
  children.push(row(actions, spacing=8.0, align=@style.CrossAlign::Center))
  ui_card(children, width=992.0)
}

///|
fn machines_page(model : Model) -> @moui.View[Msg] {
  let draft = model.draft
  let form : Array[@moui.View[Msg]] = [
    ui_section("Add machine"),
    row([
      ui_field(
        "Name",
        draft.name,
        fn(value) { DraftName(value) },
        "name",
        220.0,
      ),
      ui_field(
        "Host",
        draft.host,
        fn(value) { DraftHost(value) },
        "host (required)",
        280.0,
      ),
      ui_field("Port", draft.port, fn(value) { DraftPort(value) }, "port", 90.0),
      ui_field(
        "User",
        draft.user,
        fn(value) { DraftUser(value) },
        "user",
        160.0,
      ),
    ], spacing=12.0, align=@style.CrossAlign::End),
    row([
      ui_field(
        "Identity file",
        draft.identity,
        fn(value) { DraftIdentity(value) },
        "identity file (optional)",
        320.0,
      ),
      checkbox(
        "use ~/.ssh/config",
        checked=draft.use_ssh_config,
        on_change=fn(value) { DraftUseConfig(value) },
      ),
      spacer(weight=1.0),
      ui_ghost("host keys: " + draft.host_key_policy, CycleDraftPolicy),
      ui_primary("Add machine", SubmitMachine),
    ], spacing=12.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if model.machine_message != "" {
    form.push(ui_muted_wrapped(model.machine_message, 960.0))
  }
  let saved : Array[@moui.View[Msg]] = [
    row([
      ui_section("Saved machines"),
      spacer(weight=1.0),
      ui_meta(model.machines.length().to_string() + " registered"),
    ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if model.machines.is_empty() {
    saved.push(
      ui_muted_wrapped(
        if model.machines_loaded {
          "no machines registered yet"
        } else {
          "loading machines from the host..."
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
          if entry.is_dir { "list" } else { "open" },
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
  let child = column([
    row([
      column([
        ui_row_title(record.name),
        ui_mono(record.root, 11.0),
      ], spacing=3.0, align=@style.CrossAlign::Start),
      spacer(weight=1.0),
      ui_tag(if record.is_git { "git" } else { "exclusive" }),
      ui_mono(record.id, 10.5),
      ui_ghost_small("restore", ProjectSelectWorkspace(record.id)),
    ], spacing=12.0, align=@style.CrossAlign::Center).frame(width=964.0),
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
      let files : Array[@moui.View[Msg]] = [
        ui_section("Files"),
        ui_mono_wrapped(
          "workspace " +
          record.id +
          " · root " +
          record.root +
          " · " +
          (if record.is_git { "git" } else { "non-git (exclusive lease)" }),
          10.5,
          960.0,
          ui_dim(),
        ),
      ]
      if project.entries.is_empty() {
        files.push(ui_muted_wrapped("no entries loaded", 960.0))
      } else {
        for entry in project.entries {
          files.push(entry_row(model, entry))
        }
      }
      detail.push(ui_card(files, width=992.0))
      let editor : Array[@moui.View[Msg]] = [
        ui_section("Editor"),
        ui_meta(
          if project.selected == "" {
            "select a file"
          } else {
            project.selected + (if project.dirty { " · unsaved" } else { "" })
          },
        ),
        ui_text_area_field(
          "Content",
          project.content,
          fn(value) { ProjectDraft(value) },
          "file content",
          960.0,
          8,
        ),
        row([
          ui_primary("Save", ProjectSaveFile),
          ui_ghost("Refresh diff", ProjectRefreshDiff),
        ], spacing=8.0, align=@style.CrossAlign::Center),
      ]
      detail.push(ui_card(editor, width=992.0))
      let git : Array[@moui.View[Msg]] = [
        ui_section("Git status"),
        ui_code_block(
          if project.status_text == "" {
            "(not loaded)"
          } else {
            project.status_text
          },
          960.0,
        ),
        ui_section("Git diff"),
        ui_code_block(
          if project.diff_text == "" {
            "(no diff loaded)"
          } else {
            project.diff_text
          },
          960.0,
        ),
      ]
      detail.push(ui_card(git, width=992.0))
      let terminal : Array[@moui.View[Msg]] = [
        ui_section("Terminal"),
        ui_code_block(
          if project.terminal_text == "" {
            "(send a command to start a local PTY or remote ssh -tt + tmux session)"
          } else {
            project.terminal_text
          },
          960.0,
        ),
        row([
          ui_field(
            "Command",
            project.terminal_input,
            fn(value) { ProjectTerminalInput(value) },
            "shell command",
            800.0,
          ),
          ui_primary("Send", ProjectTerminalSend),
        ], spacing=12.0, align=@style.CrossAlign::End),
      ]
      detail.push(ui_card(terminal, width=992.0))
      let worktree : Array[@moui.View[Msg]] = [
        ui_section("Worktree"),
        row([
          ui_field(
            "Branch",
            project.worktree_branch,
            fn(value) { ProjectWorktreeBranch(value) },
            "branch",
            240.0,
          ),
          ui_field(
            "Path",
            project.worktree_path,
            fn(value) { ProjectWorktreePath(value) },
            "/absolute/worktree/path",
            440.0,
          ),
          ui_primary("Create worktree", ProjectCreateWorktree),
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
            "No project selected. Pick an open workspace in the list above or open a root.",
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
    ui_section("Open project"),
    row([
      ui_field(
        "Machine id",
        project.machine_id,
        fn(value) { ProjectMachine(value) },
        "machine id (blank = local)",
        260.0,
      ),
      ui_field(
        "Root",
        project.root,
        fn(value) { ProjectRoot(value) },
        "/absolute/project/root",
        440.0,
      ),
      ui_primary("Open project", ProjectOpen),
    ], spacing=12.0, align=@style.CrossAlign::End),
  ]
  if project.message != "" {
    open_form.push(ui_muted_wrapped(project.message, 960.0))
  }
  let workspaces : Array[@moui.View[Msg]] = [
    row([
      ui_section("Open workspaces"),
      spacer(weight=1.0),
      ui_meta(project.workspaces.length().to_string() + " open"),
    ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if project.workspaces.is_empty() {
    workspaces.push(
      ui_muted_wrapped(
        if project.workspaces_loaded {
          "no open workspaces yet"
        } else {
          "loading workspaces from the host..."
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
    ui_page_title("Agents / Sessions"),
    row([
      ui_field(
        "Agent id",
        agent.agent_id,
        fn(value) { AgentId(value) },
        "agent id",
        170.0,
      ),
      ui_field(
        "Mode",
        agent.mode,
        fn(value) { AgentMode(value) },
        "acp | stdout",
        150.0,
      ),
      ui_field(
        "Workspace",
        agent.workspace_id,
        fn(value) { AgentWorkspace(value) },
        "workspace id (blank = cwd)",
        240.0,
      ),
      ui_field(
        "Worktree",
        agent.worktree_id,
        fn(value) { AgentWorktree(value) },
        "worktree id (optional)",
        220.0,
      ),
    ], spacing=12.0, align=@style.CrossAlign::End),
    ui_text_area_field(
      "Initial prompt",
      agent.prompt,
      fn(value) { AgentPromptDraft(value) },
      "initial prompt",
      960.0,
      3,
    ),
    row([
      ui_primary("Start session", AgentStartSession),
      ui_ghost("Stop", AgentStopSession),
      ui_ghost("Resume", AgentResumeSession),
      ui_ghost("Probe", AgentProbeNow),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if agent.message != "" {
    start.push(ui_muted_wrapped(agent.message, 960.0))
  }
  let session_line = match agent.session {
    Some(record) =>
      text(
        "session " +
        record.id +
        " · " +
        (if agent.state_text == "" { record.state } else { agent.state_text }) +
        " · turns " +
        record.turns.to_string() +
        " · chunks " +
        record.chunks.to_string() +
        " · memory " +
        record.memory_bytes.to_string() +
        "B · artifacts " +
        record.artifacts.length().to_string() +
        (if agent.stop_reason == "" { "" } else { " · stop " + agent.stop_reason }),
        width=960.0,
        align=@core.TextAlign::TextStart,
        wrap=true,
      ).font(mono_font(11.0, 400)).foreground(ui_dim())
    None =>
      text("No session started yet.", width=960.0, align=@core.TextAlign::TextStart)
      .font(ui_font(12.0, 400))
      .foreground(ui_muted())
  }
  let session : Array[@moui.View[Msg]] = [
    ui_section("Session"),
    session_line,
  ]
  if agent.pending_decision != "" {
    session.push(
      text("pending decision: " + agent.pending_decision, width=960.0, align=@core.TextAlign::TextStart, wrap=true)
      .font(mono_font(11.0, 400))
      .foreground(ui_warning()),
    )
  }
  let transcript : Array[@moui.View[Msg]] = [
    ui_section("Transcript"),
    ui_code_block(
      if agent.transcript == "" { "No session yet" } else { agent.transcript },
      960.0,
      height=220.0,
      size=12.0,
    ),
    row([
      ui_field(
        "Follow-up prompt",
        agent.input,
        fn(value) { AgentInputDraft(value) },
        "follow-up prompt",
        800.0,
      ),
      ui_primary("Send", AgentSendInput),
    ], spacing=12.0, align=@style.CrossAlign::End),
  ]
  let recent : Array[@moui.View[Msg]] = [ui_section("Recent sessions")]
  if agent.sessions.is_empty() {
    recent.push(ui_muted_wrapped("(none)", 960.0))
  } else {
    for record in agent.sessions {
      recent.push(
        text(
          record.id +
          " · " +
          record.agent_id +
          " · " +
          record.state +
          " · turns " +
          record.turns.to_string() +
          " · " +
          record.cwd,
          width=960.0,
          align=@core.TextAlign::TextStart,
          wrap=true,
        ).font(mono_font(11.0, 400)).foreground(ui_dim()),
      )
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
  decision : @contracts.DecisionRecord,
) -> @moui.View[Msg] {
  let bucket = inbox_bucket_of(decision)
  let actionable = bucket == @contracts.INBOX_NEEDS_YOU
  let meta =
    "session " +
    (if decision.session_id == "" { "(none)" } else { decision.session_id }) +
    " · agent " +
    decision.agent_id +
    (if decision.run_id == "" { "" } else { " · run " + decision.run_id })
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
    body.push(ui_meta("(no detail)"))
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
      ui_ghost_small("Answer with text", InboxSubmitText(decision.id)),
    )
  }
  if answers.is_empty() {
    body.push(ui_meta("handled"))
  } else {
    body.push(row(answers, spacing=8.0, align=@style.CrossAlign::Center))
  }
  if decision.status == @contracts.DECISION_STATUS_ANSWERED {
    body.push(
      ui_meta(
        "answered by " +
        (if decision.answered_by == "" { "owner" } else { decision.answered_by }) +
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
  lines : Array[@moui.View[Msg]],
  title : String,
  items : Array[@contracts.DecisionRecord],
) -> Unit {
  if items.length() == 0 {
    return
  }
  lines.push(ui_section(title))
  for decision in items {
    lines.push(inbox_decision_card(decision))
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
  let stats = row([
    ui_stat_card("Needs you", needs.length().to_string(), "waiting on you", 322.0),
    ui_stat_card("Waiting", waiting.length().to_string(), "in flight", 322.0),
    ui_stat_card("Handled", handled.length().to_string(), "resolved", 322.0),
  ], spacing=12.0).frame(width=992.0)
  let lines : Array[@moui.View[Msg]] = [
    ui_section("Approvals"),
    ui_muted_wrapped(
      "Approvals, Agent permissions, evidence-gate waivers and recovery retries all wait in this one queue. An answer is recorded as an event and an audit record; nothing is auto-approved.",
      960.0,
    ),
  ]
  if inbox.message != "" {
    lines.push(ui_meta(inbox.message))
  }
  let queue : Array[@moui.View[Msg]] = []
  if inbox.decisions.is_empty() {
    queue.push(ui_muted_wrapped("No decisions yet.", 960.0))
  } else {
    push_inbox_section(queue, "Needs you", needs)
    push_inbox_section(queue, "Waiting", waiting)
    push_inbox_section(queue, "Handled", handled)
  }
  column([
    stats,
    ui_card(lines, width=992.0),
    column(queue, spacing=10.0),
    ui_card([
      ui_section("Answer text"),
      row([
        ui_field(
          "Free text",
          inbox.text,
          fn(value) { InboxText(value) },
          "free-text answer (questions/readiness)",
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
    "workspace " +
    (if record.workspace_id == "" { "(none)" } else { record.workspace_id }) +
    (if record.parent_id == "" { "" } else { " · parent " + record.parent_id }) +
    " · verify " +
    record.verify.length().to_string() +
    (if record.goal == "" { "" } else { " · " + record.goal })
  let child = column([
    row([
      ui_row_title_wrapped(record.title, 500.0),
      ui_tag(record.status),
      spacer(weight=1.0),
      ui_ghost_small("Select", TaskSelect(record.id)),
      ui_ghost_small("Cancel", TaskCancelNow(record.id)),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=964.0),
    row([
      ui_mono_wrapped(meta, 10.5, 720.0, ui_dim()),
      spacer(weight=1.0),
      ui_mono(record.id, 10.5),
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
  let _ = model
  let origin =
    "machine " +
    (if record.machine_id == "" { "local" } else { record.machine_id }) +
    (if record.worktree_id == "" { "" } else { " · worktree " + record.worktree_id })
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
      ui_ghost_small("Open", RunSelect(record.id)),
      ui_ghost_small("Cancel", RunCancelNow(record.id)),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
    row([
      ui_mono_wrapped(origin, 10.5, 700.0, ui_dim()),
      spacer(weight=1.0),
      ui_mono(record.id, 10.5),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ], spacing=4.0)
}

///|
fn run_detail_view(model : Model) -> @moui.View[Msg] {
  let children : Array[@moui.View[Msg]] = [ui_section("Run detail")]
  match model.task.detail {
    Some(detail) => {
      let run = detail.run
      children.push(
        row([
          text("Run " + run.id, align=@core.TextAlign::TextStart).font(ui_font(14.0, 600)).foreground(ui_text_color()),
          ui_tag(run.status),
          spacer(weight=1.0),
        ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
      )
      children.push(
        ui_mono(
          "machine " +
          (if run.machine_id == "" { "local" } else { run.machine_id }) +
          " · " +
          run.mode +
          (if run.worktree_id == "" { "" } else { " · worktree " + run.worktree_id }),
          10.5,
        ),
      )
      children.push(
        ui_code_block(
          (if run.command == "" { run.prompt } else { run.command }) +
          (if run.stop_reason == "" { "" } else { "\nstop: " + run.stop_reason }) +
          (if run.last_error == "" { "" } else { "\nerror: " + run.last_error }) +
          (if run.output_summary == "" {
            ""
          } else {
            "\nsummary: " + run.output_summary
          }),
          960.0,
        ),
      )
      children.push(ui_section("Evidence"))
      if detail.evidence.is_empty() {
        children.push(ui_muted_wrapped("(no evidence yet)", 900.0))
      } else {
        for evidence in detail.evidence {
          let evidence_body : Array[@moui.View[Msg]] = [
            row([
              text(evidence.name + " · " + evidence.kind, align=@core.TextAlign::TextStart).font(ui_font(13.0, 600)).foreground(ui_text_color()),
              spacer(weight=1.0),
              ui_tag(
                if evidence.passed {
                  "passed"
                } else if evidence.waived {
                  "waived"
                } else {
                  "failed"
                },
              ),
            ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=912.0),
            ui_mono(
              "$ " +
              evidence.command +
              " · exit " +
              evidence.exit_code.to_string(),
              10.5,
            ),
          ]
          evidence_body.push(
            ui_code_block(
              if evidence.excerpt == "" { "(no output)" } else { evidence.excerpt },
              912.0,
            ),
          )
          if evidence.artifact_id == "" {
            evidence_body.push(ui_meta("no artifact"))
          } else {
            evidence_body.push(
              row([
                ui_mono("artifact " + evidence.artifact_id, 10.5),
                spacer(weight=1.0),
                ui_ghost_small(
                  "Read",
                  ArtifactReadNow(evidence.artifact_id),
                ),
              ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=912.0),
            )
          }
          children.push(ui_card(evidence_body, padding=12.0, width=936.0))
        }
      }
      children.push(ui_section("Artifacts"))
      if detail.artifacts.is_empty() {
        children.push(ui_muted_wrapped("(no artifacts)", 900.0))
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
              ui_ghost_small("Read", ArtifactReadNow(artifact.id)),
            ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
          )
        }
      }
      if model.task.artifact_text != "" {
        children.push(ui_section("Artifact: " + model.task.artifact_name))
        children.push(ui_code_block(model.task.artifact_text, 960.0))
      }
      children.push(ui_section("Diff (HEAD)"))
      if detail.diff == "" {
        children.push(ui_muted_wrapped("(no diff / not a git worktree)", 900.0))
      } else {
        children.push(ui_code_block(detail.diff, 960.0))
      }
    }
    None =>
      children.push(
        ui_muted_wrapped(
          "Select a run to inspect evidence, artifacts and the diff.",
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
      ui_section("Activity"),
      spacer(weight=1.0),
      ui_meta(
        "cursor " +
        model.task.event_seq.to_string() +
        " · " +
        events.length().to_string() +
        " cached",
      ),
    ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if events.is_empty() {
    children.push(ui_muted_wrapped("(no events yet)", 900.0))
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
    ui_section("Create task"),
    row([
      ui_field(
        "Title",
        state.title,
        fn(value) { TaskTitle(value) },
        "task title (required)",
        440.0,
      ),
      ui_field(
        "Workspace id",
        state.workspace_id,
        fn(value) { TaskWorkspace(value) },
        "blank = open Project",
        340.0,
      ),
    ], spacing=12.0, align=@style.CrossAlign::End),
    ui_field(
      "Goal",
      state.goal,
      fn(value) { TaskGoal(value) },
      "goal (optional)",
      560.0,
    ),
    ui_text_area_field(
      "Verify commands",
      state.verify_text,
      fn(value) { TaskVerify(value) },
      "verify commands, one per line",
      960.0,
      3,
    ),
    row([
      ui_primary("Create", TaskCreateSubmit),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center),
  ]
  if state.message != "" {
    create.push(ui_muted_wrapped(state.message, 960.0))
  }
  let board : Array[@moui.View[Msg]] = [
    row([
      ui_section("Board"),
      spacer(weight=1.0),
      ui_meta(
        state.tasks.length().to_string() +
        (if state.tasks.length() == 1 { " task" } else { " tasks" }),
      ),
    ], spacing=10.0, align=@style.CrossAlign::Center).frame(width=960.0),
  ]
  if state.tasks.is_empty() {
    board.push(ui_muted_wrapped("No tasks yet.", 960.0))
  } else {
    for record in state.tasks {
      board.push(task_card(model, record))
    }
  }
  if state.selected_task != "" {
    let runs : Array[@moui.View[Msg]] = [
      row([
        ui_section("Runs for " + state.selected_task),
        spacer(weight=1.0),
        ui_meta(
          state.runs.length().to_string() +
          (if state.runs.length() == 1 { " run" } else { " runs" }),
        ),
      ], spacing=8.0, align=@style.CrossAlign::Center).frame(width=960.0),
    ]
    if state.runs.is_empty() {
      runs.push(ui_muted_wrapped("(no runs yet)", 900.0))
    } else {
      for record in state.runs {
        runs.push(run_row(model, record))
      }
    }
    runs.push(
      row([
        ui_field(
          "Command",
          state.command,
          fn(value) { TaskCommand(value) },
          "command to run in the worktree",
          520.0,
        ),
        ui_field(
          "Machine id",
          state.machine_id,
          fn(value) { TaskMachine(value) },
          "blank = local",
          220.0,
        ),
        ui_primary("Dispatch run", RunDispatch),
      ], spacing=12.0, align=@style.CrossAlign::End),
    )
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
    ui_section("Search sessions"),
    row([
      ui_field(
        "Query",
        state.query,
        fn(value) { SearchQuery(value) },
        "e.g. verify failed, flaky test, waived",
        760.0,
      ),
      ui_primary("Search", SearchSubmit),
    ], spacing=12.0, align=@style.CrossAlign::End),
    ui_meta("Search session transcripts and decision text recorded by the host."),
    ui_meta(
      if state.backend == "" {
        "FTS5 when available, LIKE otherwise"
      } else {
        "backend: " + state.backend
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
          "No hits yet. Search matches session transcripts and decision text.",
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
    ui_section("Connection"),
    ui_mono("state: " + host.link.label(), 11.0),
    ui_mono(
      "host address: " +
      (if host.ws_url == "" {
        "(waiting for host.json)"
      } else {
        host.ws_url
      }),
      11.0,
    ),
    ui_mono("token: " + host.token_status, 11.0),
    ui_mono(
      "version: " + (if host.version == "" { "(not connected)" } else { host.version }),
      11.0,
    ),
    ui_mono("data directory: " + host.state_dir, 11.0),
    ui_mono(
      "host id: " +
      (if host.host_id == "" { "(not connected)" } else { host.host_id }),
      11.0,
    ),
  ]
  if host.last_error != "" {
    connection.push(
      text("last error: " + host.last_error, width=960.0, align=@core.TextAlign::TextStart, wrap=true)
      .font(ui_font(11.0, 400))
      .foreground(ui_danger()),
    )
  }
  let appearance : Array[@moui.View[Msg]] = [
    ui_section("Appearance"),
    row([
      ui_segment("Light", Light, model.theme_mode),
      ui_segment("Dark", Dark, model.theme_mode),
      spacer(weight=1.0),
    ], spacing=8.0, align=@style.CrossAlign::Center),
    ui_meta("Applies immediately. Not persisted; MONEXUS_THEME picks the startup mode."),
  ]
  let local_host : Array[@moui.View[Msg]] = [
    ui_section("Local host"),
    ui_muted_wrapped(
      "Start or reuse the host and open this window with `monexus`. Headless machines: `monexus start --headless`.",
      960.0,
    ),
  ]
  column([
    ui_card(connection, width=992.0),
    ui_card(appearance, width=992.0),
    ui_card(local_host, width=992.0),
  ], spacing=16.0)
}

///|
fn page_body(model : Model) -> @moui.View[Msg] {
  match model.page {
    Home => home_page(model)
    Machines => machines_page(model)
    Projects => projects_page(model)
    Agents => agents_page(model)
    Inbox => inbox_page(model)
    Tasks => tasks_page(model)
    Search => search_page(model)
    Settings => settings_page(model)
  }
}

///|
fn main_island(model : Model) -> @moui.View[Msg] {
  let body = scroll_view(
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
