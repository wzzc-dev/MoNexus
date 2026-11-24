///|
using @views {
  button,
  card,
  center,
  checkbox,
  column,
  row,
  spacer,
  tag,
  text,
  text_area,
  text_field,
}

///|
fn nav_button(page : Page, current : Page) -> @moui.View[Msg] {
  let label = page.label()
  let view = button(label, on_click=SelectPage(page))
  if page.label() == current.label() {
    view.title()
  } else {
    view
  }
}

///|
fn host_summary(host : HostProjection) -> @moui.View[Msg] {
  let lines : Array[@moui.View[Msg]] = [
    text("MoNexus host: " + host.link.label()),
    text(
      if host.host_id == "" {
        "host id: (not connected)"
      } else {
        "host id: " + host.host_id
      },
    ),
  ]
  if host.version != "" {
    lines.push(text("version: " + host.version))
  }
  if host.ws_url != "" {
    lines.push(text("endpoint: " + host.ws_url).caption())
  }
  if host.event_count > 0 {
    lines.push(
      text(
        "events: " +
        host.event_count.to_string() +
        " (last " +
        host.last_event +
        " @" +
        host.event_seq.to_string() +
        ")",
      ).caption(),
    )
  }
  if host.last_error != "" {
    lines.push(text("reason: " + host.last_error).caption())
  }
  column(lines, spacing=6.0)
}

///|
fn machine_card(model : Model, record : @contracts.MachineRecord) -> @moui.View[Msg] {
  let busy = model.machine_busy == record.id
  let identity = if record.identity == "" {
    "(default)"
  } else {
    record.identity
  }
  let lines : Array[@moui.View[Msg]] = [
    row([
      text(record.name).title(),
      spacer(weight=1.0),
      tag(machine_status_text(record.status)),
    ], spacing=8.0),
    text(
      record.target_label() +
      ":" +
      record.port.to_string() +
      " · identity " +
      identity +
      " · config " +
      (if record.use_ssh_config { "on" } else { "off" }),
    ).caption(),
    text(
      "host keys " +
      record.host_key_policy +
      " · " +
      machine_profile_summary(record),
    ).caption(),
  ]
  if record.last_error != "" {
    lines.push(text("reason: " + record.last_error).caption())
  }
  let actions : Array[@moui.View[Msg]] = [
    button("Probe", on_click=ProbeMachine(record.id)),
    button("Remove", on_click=RemoveMachine(record.id)),
  ]
  if busy {
    actions.push(text("working...").caption())
  }
  lines.push(row(actions, spacing=8.0))
  card(column(lines, spacing=4.0), padding=10.0)
}

///|
fn machines_page(model : Model) -> @moui.View[Msg] {
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Machines").title(),
      spacer(weight=1.0),
      button("Refresh", on_click=RefreshMachines),
    ], spacing=8.0),
    text(
      "Explicit host/port/user/identity. Turn config off to pin the target and ignore ~/.ssh/config.",
    ).caption(),
    row([
      text_field(
        model.draft.name,
        on_input=fn(value) { DraftName(value) },
        placeholder="name",
        width=200.0,
      ),
      text_field(
        model.draft.port,
        on_input=fn(value) { DraftPort(value) },
        placeholder="port",
        width=90.0,
      ),
    ], spacing=8.0),
    row([
      text_field(
        model.draft.host,
        on_input=fn(value) { DraftHost(value) },
        placeholder="host (required)",
        width=300.0,
      ),
      text_field(
        model.draft.user,
        on_input=fn(value) { DraftUser(value) },
        placeholder="user",
        width=140.0,
      ),
    ], spacing=8.0),
    row([
      text_field(
        model.draft.identity,
        on_input=fn(value) { DraftIdentity(value) },
        placeholder="identity file (optional)",
        width=300.0,
      ),
      checkbox(
        "use ~/.ssh/config",
        checked=model.draft.use_ssh_config,
        on_change=fn(value) { DraftUseConfig(value) },
      ),
    ], spacing=8.0),
    row([
      button(
        "host keys: " + model.draft.host_key_policy,
        on_click=CycleDraftPolicy,
      ),
      button("Add machine", on_click=SubmitMachine),
    ], spacing=8.0),
  ]
  if model.machine_message != "" {
    lines.push(text(model.machine_message).caption())
  }
  lines.push(text("Saved machines").title())
  if model.machines.is_empty() {
    lines.push(
      text(
        if model.machines_loaded {
          "no machines registered yet"
        } else {
          "loading machines from the host..."
        },
      ).caption(),
    )
  } else {
    for record in model.machines {
      lines.push(machine_card(model, record))
    }
  }
  column(lines, spacing=8.0)
}

///|
fn entry_row(model : Model, entry : @contracts.WorkspaceEntry) -> @moui.View[Msg] {
  let label = if entry.is_dir {
    "[dir] " + entry.name
  } else {
    entry.name
  }
  let selected = model.project.selected == entry.path
  let line = row([
    text(label).mono(),
    spacer(weight=1.0),
    button(
      if entry.is_dir { "list" } else { "open" },
      on_click=if entry.is_dir {
        ProjectOpenDir(entry.path)
      } else {
        ProjectOpenFile(entry.path)
      },
    ),
  ], spacing=8.0)
  if selected {
    line.title()
  } else {
    line
  }
}

///|
fn project_page(model : Model) -> @moui.View[Msg] {
  let project = model.project
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Projects").title(),
      spacer(weight=1.0),
      button("Refresh", on_click=ProjectRefresh),
    ], spacing=8.0),
    text(
      "Open a local or SSH project by machine id + absolute root. Both use the same workspace RPC surface.",
    ).caption(),
    row([
      text_field(
        project.machine_id,
        on_input=fn(value) { ProjectMachine(value) },
        placeholder="machine id (blank = local)",
        width=260.0,
      ),
      text_field(
        project.root,
        on_input=fn(value) { ProjectRoot(value) },
        placeholder="/absolute/project/root",
        width=320.0,
      ),
      button("Open project", on_click=ProjectOpen),
    ], spacing=8.0),
  ]
  if project.message != "" {
    lines.push(text(project.message).caption())
  }
  match project.workspace {
    Some(record) => {
      lines.push(
        text(
          "workspace " +
          record.id +
          " · root " +
          record.root +
          " · " +
          (if record.is_git { "git" } else { "non-git (exclusive lease)" }),
        ).caption(),
      )
      lines.push(text("Files").title())
      if project.entries.is_empty() {
        lines.push(text("no entries loaded").caption())
      } else {
        for entry in project.entries {
          lines.push(entry_row(model, entry))
        }
      }
      lines.push(
        text(
          if project.selected == "" {
            "Editor (select a file)"
          } else {
            "Editor · " +
            project.selected +
            (if project.dirty { " *unsaved*" } else { "" })
          },
        ).title(),
      )
      lines.push(
        text_area(
          project.content,
          on_input=fn(value) { ProjectDraft(value) },
          placeholder="file content",
          lines=8,
          width=700.0,
        ),
      )
      lines.push(
        row([
          button("Save", on_click=ProjectSaveFile),
          button("Refresh diff", on_click=ProjectRefreshDiff),
        ], spacing=8.0),
      )
      lines.push(text("Git status").title())
      lines.push(
        text(
          if project.status_text == "" {
            "(not loaded)"
          } else {
            project.status_text
          },
        ).mono(),
      )
      lines.push(text("Git diff").title())
      lines.push(
        text(
          if project.diff_text == "" {
            "(no diff loaded)"
          } else {
            project.diff_text
          },
        ).mono(),
      )
      lines.push(text("Terminal").title())
      lines.push(
        text(
          if project.terminal_text == "" {
            "(send a command to start a local PTY or remote ssh -tt + tmux session)"
          } else {
            project.terminal_text
          },
        ).mono(),
      )
      lines.push(
        row([
          text_field(
            project.terminal_input,
            on_input=fn(value) { ProjectTerminalInput(value) },
            placeholder="shell command",
            width=520.0,
          ),
          button("Send", on_click=ProjectTerminalSend),
        ], spacing=8.0),
      )
      lines.push(text("Worktree").title())
      lines.push(
        row([
          text_field(
            project.worktree_branch,
            on_input=fn(value) { ProjectWorktreeBranch(value) },
            placeholder="branch",
            width=200.0,
          ),
          text_field(
            project.worktree_path,
            on_input=fn(value) { ProjectWorktreePath(value) },
            placeholder="/absolute/worktree/path",
            width=320.0,
          ),
          button("Create worktree", on_click=ProjectCreateWorktree),
        ], spacing=8.0),
      )
      if project.worktree_message != "" {
        lines.push(text(project.worktree_message).caption())
      }
    }
    None => lines.push(text("No project open yet.").caption())
  }
  column(lines, spacing=8.0)
}

///|
fn page_body(model : Model) -> @moui.View[Msg] {
  match model.page {
    Home =>
      column([
        text("Welcome to MoNexus").title(),
        text(
          "A local-first desktop shell for machines, tasks and agent sessions.",
        ),
        host_summary(model.host),
      ], spacing=10.0)
    Machines => machines_page(model)
    Projects => project_page(model)
    Tasks =>
      column([
        text("Tasks").title(),
        text("Tasks page"),
        text("M3 will show task runs and their event streams here."),
      ], spacing=10.0)
    Search =>
      column([
        text("Search").title(),
        text("Search page"),
        text("M4 will wire ACP-backed search and results here."),
      ], spacing=10.0)
    Settings =>
      column([
        text("Settings").title(),
        text("Settings page"),
        text("state dir: " + model.host.state_dir).mono(),
        text("Token and endpoint come from host.json (mode 0600).").caption(),
      ], spacing=10.0)
  }
}

///|
pub fn view(model : Model) -> @moui.View[Msg] {
  let nav : Array[@moui.View[Msg]] = []
  for page in [Home, Machines, Projects, Tasks, Search, Settings] {
    nav.push(nav_button(page, model.page))
  }
  center(
    card(
      column([
        row([
          text("MoNexus").title(),
          spacer(weight=1.0),
          text("host " + model.host.link.label()),
        ], spacing=16.0),
        row(nav, spacing=8.0),
        card(page_body(model)),
      ], spacing=16.0),
      padding=20.0,
    ),
    width=920.0,
    height=560.0,
  )
}
