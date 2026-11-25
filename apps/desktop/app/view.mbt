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
fn agents_page(model : Model) -> @moui.View[Msg] {
  let agent = model.agent
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Agents / Sessions").title(),
      spacer(weight=1.0),
      button("Probe", on_click=AgentProbeNow),
      button("Refresh", on_click=AgentRefresh),
    ], spacing=8.0),
    text(
      "Starts a local ACP adapter (default: npx @zed-industries/claude-code-acp). The adapter needs a logged-in agent account.",
    ).caption(),
    row([
      text_field(
        agent.agent_id,
        on_input=fn(value) { AgentId(value) },
        placeholder="agent id",
        width=170.0,
      ),
      text_field(
        agent.mode,
        on_input=fn(value) { AgentMode(value) },
        placeholder="mode (acp|stdout)",
        width=150.0,
      ),
      text_field(
        agent.workspace_id,
        on_input=fn(value) { AgentWorkspace(value) },
        placeholder="workspace id (blank = cwd)",
        width=240.0,
      ),
      text_field(
        agent.worktree_id,
        on_input=fn(value) { AgentWorktree(value) },
        placeholder="worktree id (optional)",
        width=220.0,
      ),
    ], spacing=8.0),
    text_area(
      agent.prompt,
      on_input=fn(value) { AgentPromptDraft(value) },
      placeholder="initial prompt",
      lines=3,
      width=700.0,
    ),
    row([
      button("Start session", on_click=AgentStartSession),
      button("Stop", on_click=AgentStopSession),
      button("Resume", on_click=AgentResumeSession),
    ], spacing=8.0),
  ]
  if agent.message != "" {
    lines.push(text(agent.message).caption())
  }
  match agent.session {
    Some(record) =>
      lines.push(
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
          (if agent.stop_reason == "" {
            ""
          } else {
            " · stop " + agent.stop_reason
          }),
        ).caption(),
      )
    None => lines.push(text("No session started yet.").caption())
  }
  lines.push(text("Transcript").title())
  lines.push(
    text(
      if agent.transcript == "" {
        "(waiting for output)"
      } else {
        agent.transcript
      },
    ).mono(),
  )
  lines.push(
    row([
      text_field(
        agent.input,
        on_input=fn(value) { AgentInputDraft(value) },
        placeholder="follow-up prompt",
        width=520.0,
      ),
      button("Send", on_click=AgentSendInput),
    ], spacing=8.0),
  )
  lines.push(text("Recent sessions").title())
  if agent.sessions.is_empty() {
    lines.push(text("(none)").caption())
  } else {
    for record in agent.sessions {
      lines.push(
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
        ).caption(),
      )
    }
  }
  column(lines, spacing=8.0)
}

///|
fn inbox_decision_card(decision : @contracts.DecisionRecord) -> @moui.View[Msg] {
  let bucket = inbox_bucket_of(decision)
  let actionable = bucket == @contracts.INBOX_NEEDS_YOU
  let actions : Array[@moui.View[Msg]] = []
  if actionable {
    for option in decision.options {
      actions.push(
        button(
          option.name,
          on_click=InboxAnswer(decision.id, option.option_id),
        ),
      )
    }
    actions.push(
      button("Answer with text", on_click=InboxSubmitText(decision.id)),
    )
  }
  card(
    column([
      row([
        text(decision.kind + ": " + decision.title).title(),
        spacer(weight=1.0),
        tag(decision.status),
        tag(bucket),
      ], spacing=8.0),
      text(
        "session " +
        (if decision.session_id == "" { "(none)" } else { decision.session_id }) +
        " · agent " +
        decision.agent_id +
        (if decision.run_id == "" { "" } else { " · run " + decision.run_id }),
      ).caption(),
      if decision.detail == "" {
        text("(no detail)").caption()
      } else {
        text(decision.detail).mono()
      },
      if decision.status == @contracts.DECISION_STATUS_ANSWERED {
        text(
          "answered by " +
          (if decision.answered_by == "" { "owner" } else { decision.answered_by }) +
          (if decision.option_id == "" { "" } else { " · " + decision.option_id }) +
          (if decision.answer_text == "" { "" } else { " · " + decision.answer_text }),
        ).caption()
      } else {
        text("(no answer yet)").caption()
      },
      if actions.length() == 0 {
        text("handled").caption()
      } else {
        row(actions, spacing=8.0)
      },
    ], spacing=6.0),
    padding=10.0,
  )
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
  lines.push(text(title).title())
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
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Inbox").title(),
      spacer(weight=1.0),
      button("Refresh", on_click=InboxRefresh),
    ], spacing=8.0),
    text(
      "Approvals, Agent permissions, evidence-gate waivers and recovery retries all wait in this one queue. An answer is recorded as an event and an audit record; nothing is auto-approved.",
    ).caption(),
  ]
  if inbox.message != "" {
    lines.push(text(inbox.message).caption())
  }
  if inbox.decisions.is_empty() {
    lines.push(text("No decisions yet.").caption())
  } else {
    push_inbox_section(lines, "Needs you", needs)
    push_inbox_section(lines, "Waiting", waiting)
    push_inbox_section(lines, "Handled", handled)
  }
  lines.push(
    row([
      text_field(
        inbox.text,
        on_input=fn(value) { InboxText(value) },
        placeholder="free-text answer (questions/readiness)",
        width=520.0,
      ),
    ], spacing=8.0),
  )
  column(lines, spacing=8.0)
}

///|
fn task_row(model : Model, record : @contracts.TaskRecord) -> @moui.View[Msg] {
  let selected = model.task.selected_task == record.id
  let line = row([
    text(record.title).title(),
    tag(record.status),
    spacer(weight=1.0),
    text(record.id).caption(),
    button("select", on_click=TaskSelect(record.id)),
    button("cancel", on_click=TaskCancelNow(record.id)),
  ], spacing=8.0)
  let lines : Array[@moui.View[Msg]] = [
    if selected { line.title() } else { line },
    text(
      "workspace " +
      (if record.workspace_id == "" { "(none)" } else { record.workspace_id }) +
      (if record.parent_id == "" { "" } else { " · parent " + record.parent_id }) +
      " · verify " +
      record.verify.length().to_string() +
      (if record.goal == "" { "" } else { " · " + record.goal }),
    ).caption(),
  ]
  card(column(lines, spacing=4.0), padding=8.0)
}

///|
fn run_row(model : Model, record : @contracts.RunRecord) -> @moui.View[Msg] {
  let selected = model.task.selected_run == record.id
  let line = row([
    text(record.mode + ": " + record.command).mono(),
    tag(record.status),
    spacer(weight=1.0),
    text(
      if record.machine_id == "" {
        "local"
      } else {
        record.machine_id
      },
    ).caption(),
    button("open", on_click=RunSelect(record.id)),
    button("cancel", on_click=RunCancelNow(record.id)),
  ], spacing=8.0)
  if selected {
    line.title()
  } else {
    line
  }
}

///|
fn run_detail_view(model : Model) -> @moui.View[Msg] {
  let detail = match model.task.detail {
    Some(value) => value
    None =>
      return column([
        text("Run detail").title(),
        text("Select a run to inspect evidence, artifacts and the diff.").caption(),
      ], spacing=6.0)
  }
  let run = detail.run
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Run " + run.id).title(),
      tag(run.status),
      spacer(weight=1.0),
      text(
        (if run.machine_id == "" { "local" } else { run.machine_id }) +
        " · " +
        run.mode +
        (if run.worktree_id == "" {
          ""
        } else {
          " · worktree " + run.worktree_id
        }),
      ).caption(),
    ], spacing=8.0),
    text(
      (if run.command == "" { run.prompt } else { run.command }) +
      (if run.stop_reason == "" { "" } else { "\nstop: " + run.stop_reason }) +
      (if run.last_error == "" { "" } else { "\nerror: " + run.last_error }) +
      (if run.output_summary == "" { "" } else { "\nsummary: " + run.output_summary }),
    ).mono(),
    text("Evidence").title(),
  ]
  if detail.evidence.is_empty() {
    lines.push(text("(no evidence yet)").caption())
  } else {
    for evidence in detail.evidence {
      lines.push(
        card(
          column([
            row([
              text(evidence.name + " · " + evidence.kind).title(),
              spacer(weight=1.0),
              tag(
                if evidence.passed {
                  "passed"
                } else if evidence.waived {
                  "waived"
                } else {
                  "failed"
                },
              ),
            ], spacing=8.0),
            text("$ " + evidence.command + " · exit " + evidence.exit_code.to_string()).mono(),
            if evidence.excerpt == "" {
              text("(no output)").caption()
            } else {
              text(evidence.excerpt).mono()
            },
            if evidence.artifact_id == "" {
              text("no artifact").caption()
            } else {
              row([
                text("artifact " + evidence.artifact_id).caption(),
                button("read", on_click=ArtifactReadNow(evidence.artifact_id)),
              ], spacing=8.0)
            },
          ], spacing=4.0),
          padding=8.0,
        ),
      )
    }
  }
  lines.push(text("Artifacts").title())
  if detail.artifacts.is_empty() {
    lines.push(text("(no artifacts)").caption())
  } else {
    for artifact in detail.artifacts {
      lines.push(
        row([
          text(
            artifact.kind +
            " · " +
            artifact.size.to_string() +
            "B · " +
            artifact.uri,
          ).mono(),
          spacer(weight=1.0),
          button("read", on_click=ArtifactReadNow(artifact.id)),
        ], spacing=8.0),
      )
    }
  }
  if model.task.artifact_text != "" {
    lines.push(
      text("Artifact: " + model.task.artifact_name).title(),
    )
    lines.push(text(model.task.artifact_text).mono())
  }
  lines.push(text("Diff (HEAD)").title())
  lines.push(
    text(
      if detail.diff == "" {
        "(no diff / not a git worktree)"
      } else {
        detail.diff
      },
    ).mono(),
  )
  column(lines, spacing=8.0)
}

///|
fn activity_view(model : Model) -> @moui.View[Msg] {
  let events = model.task.events
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Activity").title(),
      spacer(weight=1.0),
      text(
        "cursor " +
        model.task.event_seq.to_string() +
        " · " +
        events.length().to_string() +
        " cached",
      ).caption(),
    ], spacing=8.0),
  ]
  if events.is_empty() {
    lines.push(text("(no events yet)").caption())
  } else {
    let start = if events.length() > 30 { events.length() - 30 } else { 0 }
    let mut index = start
    while index < events.length() {
      let event = events[index]
      lines.push(
        text(
          "#" +
          event.seq.to_string() +
          " " +
          event.event_type +
          " · " +
          event.subject,
        ).mono(),
      )
      index = index + 1
    }
  }
  column(lines, spacing=4.0)
}

///|
fn tasks_page(model : Model) -> @moui.View[Msg] {
  let state = model.task
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Tasks").title(),
      spacer(weight=1.0),
      button("Refresh", on_click=TasksRefresh),
    ], spacing=8.0),
    text(
      "Create a ready task, then dispatch command runs to local or SSH machines. Runs pass through verifying: every verify[] command must pass or be explicitly waived.",
    ).caption(),
    row([
      text_field(
        state.title,
        on_input=fn(value) { TaskTitle(value) },
        placeholder="task title (required)",
        width=320.0,
      ),
      text_field(
        state.workspace_id,
        on_input=fn(value) { TaskWorkspace(value) },
        placeholder="workspace id (blank = open Project)",
        width=260.0,
      ),
      button("Create ready task", on_click=TaskCreateSubmit),
    ], spacing=8.0),
    row([
      text_field(
        state.goal,
        on_input=fn(value) { TaskGoal(value) },
        placeholder="goal (optional)",
        width=320.0,
      ),
      text_field(
        state.verify_text,
        on_input=fn(value) { TaskVerify(value) },
        placeholder="verify commands, one per line",
        width=420.0,
      ),
    ], spacing=8.0),
  ]
  if state.message != "" {
    lines.push(text(state.message).caption())
  }
  lines.push(text("Board").title())
  if state.tasks.is_empty() {
    lines.push(text("No tasks yet.").caption())
  } else {
    for record in state.tasks {
      lines.push(task_row(model, record))
    }
  }
  if state.selected_task != "" {
    lines.push(text("Runs for " + state.selected_task).title())
    if state.runs.is_empty() {
      lines.push(text("(no runs yet)").caption())
    } else {
      for record in state.runs {
        lines.push(run_row(model, record))
      }
    }
    lines.push(
      row([
        text_field(
          state.command,
          on_input=fn(value) { TaskCommand(value) },
          placeholder="command to run in the worktree",
          width=420.0,
        ),
        text_field(
          state.machine_id,
          on_input=fn(value) { TaskMachine(value) },
          placeholder="machine id (blank = local)",
          width=220.0,
        ),
        button("Dispatch run", on_click=RunDispatch),
      ], spacing=8.0),
    )
  }
  lines.push(run_detail_view(model))
  lines.push(activity_view(model))
  column(lines, spacing=9.0)
}

///|
fn search_page(model : Model) -> @moui.View[Msg] {
  let state = model.search
  let lines : Array[@moui.View[Msg]] = [
    row([
      text("Search").title(),
      spacer(weight=1.0),
      text(
        if state.backend == "" {
          "FTS5 when available, LIKE otherwise"
        } else {
          "backend: " + state.backend
        },
      ).caption(),
    ], spacing=8.0),
    text(
      "Search session transcripts and decision text recorded by the host.",
    ).caption(),
    row([
      text_field(
        state.query,
        on_input=fn(value) { SearchQuery(value) },
        placeholder="e.g. verify failed, flaky test, waived",
        width=480.0,
      ),
      button("Search", on_click=SearchSubmit),
    ], spacing=8.0),
  ]
  if state.message != "" {
    lines.push(text(state.message).caption())
  }
  if state.hits.is_empty() {
    lines.push(text("(no hits)").caption())
  } else {
    for hit in state.hits {
      lines.push(
        card(
          column([
            row([
              tag(hit.kind),
              text(hit.title).title(),
              spacer(weight=1.0),
              text(hit.ref_id).caption(),
            ], spacing=8.0),
            text(hit.snippet).mono(),
            text(hit.ts).caption(),
          ], spacing=4.0),
          padding=8.0,
        ),
      )
    }
  }
  column(lines, spacing=8.0)
}

///|
/// M7 Settings: where the shell points, whether the bearer token is present,
/// the host version and the data directory. The token itself is never shown;
/// it stays in `host.json` (0600) and the UI only reports its status.
fn settings_page(model : Model) -> @moui.View[Msg] {
  let host = model.host
  let lines : Array[@moui.View[Msg]] = [
    text("Settings").title(),
    text("Connection").caption(),
    text("state: " + host.link.label()),
    text(
      if host.ws_url == "" {
        "host address: (waiting for host.json)"
      } else {
        "host address: " + host.ws_url
      },
    ).mono(),
    text("token: " + host.token_status).mono(),
    text(
      if host.version == "" {
        "version: (not connected)"
      } else {
        "version: " + host.version
      },
    ),
    text("data directory: " + host.state_dir).mono(),
    text(
      "host id: " +
      (if host.host_id == "" { "(not connected)" } else { host.host_id }),
    ).caption(),
    text(
      "Start or reuse the host and open this window with `monexus`. " +
      "Headless machines: `monexus start --headless`.",
    ).caption(),
  ]
  if host.last_error != "" {
    lines.push(text("last error: " + host.last_error).caption())
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
    Agents => agents_page(model)
    Inbox => inbox_page(model)
    Tasks => tasks_page(model)
    Search => search_page(model)
    Settings => settings_page(model)
  }
}

///|
pub fn view(model : Model) -> @moui.View[Msg] {
  let nav : Array[@moui.View[Msg]] = []
  for page in [Home, Machines, Projects, Agents, Inbox, Tasks, Search, Settings] {
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
