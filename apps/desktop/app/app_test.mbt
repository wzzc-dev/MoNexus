///|
test "the shell renders the header and the Home page" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=1280.0,
    height=800.0,
  )
  assert_true(harness.has_text("MoNexus"))
  assert_true(harness.has_text("Welcome to MoNexus"))
  assert_true(harness.has_text("host connecting"))
}

///|
test "all eight pages can be switched by tapping navigation" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=1280.0,
    height=800.0,
  )
  harness.tap_text("Machines")
  assert_true(harness.has_text("Add machine"))
  assert_true(harness.has_text("Saved machines"))
  harness.tap_text("Agents")
  assert_true(harness.has_text("Agents / Sessions"))
  assert_true(harness.has_text("Start session"))
  harness.tap_text("Inbox")
  assert_true(harness.has_text("No decisions yet."))
  harness.tap_text("Tasks")
  assert_true(harness.has_text("Board"))
  harness.tap_text("Search")
  assert_true(
    harness.has_text(
      "Search session transcripts and decision text recorded by the host.",
    ),
  )
  harness.tap_text("Settings")
  assert_true(harness.has_text("Connection"))
  assert_true(harness.has_text("token: unknown (host not connected)"))
  assert_true(harness.has_text("host address: (waiting for host.json)"))
  harness.tap_text("Home")
  assert_true(harness.has_text("Welcome to MoNexus"))
}

///|
test "host status and events are reflected in the model" {
  let model = Model::new()
  let online = update(
    model,
    LinkOnline({
      host_id: "host_test",
      version: "0.1.0-m1",
      ws_url: "ws://127.0.0.1:1234/ws",
      token_status: "present (host.json, never displayed)",
      state_dir: "/tmp/monexus-test",
      event_seq: 7L,
    }),
  )
  assert_eq(online.host.link.label(), "online")
  assert_eq(online.host.host_id, "host_test")
  assert_eq(online.host.event_seq, 7L)
  let arrived = update(online, EventArrived("host.heartbeat", 8L))
  assert_eq(arrived.host.event_count, 1)
  assert_eq(arrived.host.event_seq, 8L)
  let offline = update(arrived, LinkOffline("connection closed"))
  assert_eq(offline.host.link.label(), "offline")
  assert_eq(offline.host.last_error, "connection closed")
}

///|
test "page selection is stable across link updates" {
  let model = update(Model::new(), SelectPage(Settings))
  let online = update(
    model,
    LinkOnline({
      host_id: "host_test",
      version: "0.1.0-m1",
      ws_url: "ws://127.0.0.1:1234/ws",
      token_status: "present (host.json, never displayed)",
      state_dir: "/tmp/monexus-test",
      event_seq: 0L,
    }),
  )
  assert_eq(online.page.label(), "Settings")
  assert_eq(Model::new().page.label(), "Home")
}

///|
/// Local record builder: the app's scene helper is package-private, and the
/// tests only need a deterministic projection.
fn test_machine(
  id : String,
  name : String,
  status : String,
  last_error : String,
) -> @contracts.MachineRecord {
  {
    id,
    kind: @contracts.MACHINE_KIND_SSH,
    name,
    host: "127.0.0.1",
    port: 2222,
    user: "tester",
    identity: "/tmp/key",
    use_ssh_config: false,
    host_key_policy: @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    known_hosts_file: "",
    status,
    profile: None,
    ssh_effective: Map([]),
    ssh_effective_error: "",
    last_seen: "",
    last_error,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
}

///|
fn test_workspace_record(
  id : String,
  name : String,
  machine_id : String,
  updated_at : String,
) -> @contracts.WorkspaceRecord {
  {
    id,
    machine_id,
    kind: if machine_id == "" { "local" } else { "ssh" },
    root: "/tmp/" + name,
    name,
    git_root: "/tmp/" + name,
    is_git: true,
    state: "open",
    created_at: "2026-01-01T00:00:00Z",
    updated_at,
  }
}

///|
fn test_agent_session(
  id : String,
  agent_id : String,
  workspace_id : String,
  updated_at : String,
) -> @contracts.AgentSessionRecord {
  let base = @contracts.AgentSessionRecord::new(
    id~,
    agent_id~,
    mode=@contracts.AGENT_MODE_ACP,
    cwd="/tmp/demo",
    started_at=updated_at,
  )
  {
    ..base,
    workspace_id,
    agent_name: "Planner",
    state: @contracts.AGENT_STATE_IDLE,
    updated_at,
    turns: 2,
  }
}

///|
test "machine draft validation produces a readable error and no command" {
  let model = Model::new()
  let empty = update_full(model, SubmitMachine)
  assert_eq(empty.1.length(), 0)
  assert_true(empty.0.machine_message.contains("host is required"))
  let bad_port = update_full(
    update(empty.0, DraftHost("127.0.0.1")),
    DraftPort("not-a-port"),
  )
  let submitted = update_full(bad_port.0, SubmitMachine)
  assert_eq(submitted.1.length(), 0)
  assert_true(submitted.0.machine_message.contains("port must be 1-65535"))
}

///|
test "valid machine draft submits an add command with a default name" {
  let model = update(Model::new(), DraftHost("127.0.0.1"))
  let model = update(model, DraftPort("2222"))
  let model = update(model, DraftUser("tester"))
  let model = update(model, DraftIdentity("/tmp/key"))
  let model = update(model, DraftUseConfig(false))
  let (next, commands) = update_full(model, SubmitMachine)
  assert_eq(commands.length(), 1)
  match commands[0] {
    AddMachine(draft) => {
      assert_eq(draft.host, "127.0.0.1")
      assert_eq(draft.port, "2222")
      assert_eq(draft.user, "tester")
      assert_eq(draft.identity, "/tmp/key")
      assert_eq(draft.use_ssh_config, false)
      // Unnamed machines default to the host, matching the host-side parser.
      assert_eq(draft.name, "127.0.0.1")
    }
    _ => fail("expected AddMachine")
  }
  assert_eq(next.machine_busy, "add")
}

///|
test "machine events upsert and remove records" {
  let online = test_machine(
    "mch_2",
    "later",
    @contracts.MACHINE_STATUS_ONLINE,
    "",
  )
  let earlier = test_machine(
    "mch_1",
    "first",
    @contracts.MACHINE_STATUS_OFFLINE,
    "Timeout: SSH connection timed out",
  )
  let model = update(Model::new(), MachineUpserted(online))
  let model = update(model, MachineUpserted(earlier))
  assert_eq(model.machines.length(), 2)
  // Sorted by created_at then id, so the list is stable across replays.
  assert_eq(model.machines[0].id, "mch_1")
  assert_eq(model.machines[1].id, "mch_2")
  assert_eq(model.machines[0].status, @contracts.MACHINE_STATUS_OFFLINE)
  assert_true(model.machines_loaded)
  let replaced = update(model, MachineUpserted({ ..online, status: @contracts.MACHINE_STATUS_DEGRADED }))
  assert_eq(replaced.machines.length(), 2)
  let removed = update(replaced, MachineRemoved("mch_1"))
  assert_eq(removed.machines.length(), 1)
  assert_eq(removed.machines[0].id, "mch_2")
}

///|
test "probe and remove set busy state, result messages clear it" {
  let model = update(Model::new(), ProbeMachine("mch_x"))
  assert_eq(model.machine_busy, "mch_x")
  let done = update(model, MachineNotice("probe: demo online"))
  assert_eq(done.machine_busy, "")
  assert_eq(done.machine_message, "probe: demo online")
  let failed = update(model, MachineError("Unauthorized: SSH authentication failed"))
  assert_eq(failed.machine_busy, "")
  assert_true(failed.machine_message.contains("Unauthorized"))
}

///|
test "refresh asks the command worker for a list" {
  let (next, commands) = update_full(Model::new(), RefreshMachines)
  assert_eq(commands.length(), 1)
  match commands[0] {
    RefreshMachines => assert_eq(next.machine_message, "")
    _ => fail("expected RefreshMachines")
  }
}

///|
test "host key policy cycles through all four values" {
  let model = Model::new()
  let steps : Array[String] = []
  let mut current = model
  for _ in 0..<4 {
    current = update(current, CycleDraftPolicy)
    steps.push(current.draft.host_key_policy)
  }
  assert_eq(steps[0], @contracts.MACHINE_HOST_KEY_POLICY_STRICT)
  assert_eq(steps[1], @contracts.MACHINE_HOST_KEY_POLICY_INSECURE)
  assert_eq(steps[2], @contracts.MACHINE_HOST_KEY_POLICY_CONFIG)
  assert_eq(steps[3], @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW)
}

///|
test "projects page opens and drives the workspace command surface" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=1280.0,
    height=800.0,
  )
  harness.tap_text("Projects")
  assert_true(harness.has_text("Open project"))
  assert_true(harness.has_text("Open workspaces"))
  assert_true(harness.has_text("loading workspaces from the host..."))
}

///|
test "project open requires a root and emits OpenProject" {
  let model = Model::new()
  let (empty, commands) = update_full(model, ProjectOpen)
  assert_eq(commands.length(), 0)
  assert_true(empty.project.message.contains("root is required"))
  let with_root = update(update(model, ProjectMachine("mch_1")), ProjectRoot("/tmp/demo"))
  let (opened, commands2) = update_full(with_root, ProjectOpen)
  assert_eq(commands2.length(), 1)
  match commands2[0] {
    OpenProject(machine_id, root) => {
      assert_eq(machine_id, "mch_1")
      assert_eq(root, "/tmp/demo")
    }
    _ => fail("expected OpenProject")
  }
  assert_true(opened.project.busy)
}

///|
test "workspace projections seed the most recent name-based selectors" {
  let older = test_workspace_record("wsp_old", "Old", "", "2026-01-01T00:00:00Z")
  let newer = test_workspace_record(
    "wsp_new",
    "New",
    "mch_1",
    "2026-01-03T00:00:00Z",
  )
  let model = update(Model::new(), ProjectWorkspaces([newer, older]))
  assert_true(model.project.workspaces_loaded)
  assert_eq(model.agent.workspace_id, "wsp_new")
  assert_eq(model.task.workspace_id, "wsp_new")
  let explicit = update(model, TaskWorkspaceSelect("wsp_old"))
  assert_eq(explicit.task.workspace_id, "wsp_old")
  let refreshed = update(explicit, ProjectWorkspaces([older, newer]))
  assert_eq(refreshed.task.workspace_id, "wsp_old")
}

///|
test "agent sessions auto-load the most recent session and read its transcript" {
  let older = test_agent_session(
    "ses_old",
    "agent_old",
    "wsp_old",
    "2026-01-01T00:00:00Z",
  )
  let newer = test_agent_session(
    "ses_new",
    "agent_new",
    "wsp_new",
    "2026-01-03T00:00:00Z",
  )
  let (model, commands) = update_full(Model::new(), AgentSessions([older, newer]))
  match model.agent.session {
    Some(record) => {
      assert_eq(record.id, "ses_new")
      assert_eq(model.agent.agent_id, "agent_new")
      assert_eq(model.agent.workspace_id, "wsp_new")
    }
    None => fail("expected the most recent agent session")
  }
  assert_eq(commands.length(), 1)
  match commands[0] {
    AgentRead(session_id) => assert_eq(session_id, "ses_new")
    _ => fail("expected AgentRead for the most recent session")
  }
}

///|
test "agent follow-up, stop and resume target the selected session" {
  let record = test_agent_session(
    "ses_live",
    "planner",
    "wsp_live",
    "2026-01-03T00:00:00Z",
  )
  let (model, _) = update_full(Model::new(), AgentSessions([record]))
  let drafted = update(model, AgentInputDraft("continue the review"))
  let (sent, send_commands) = update_full(drafted, AgentSendInput)
  assert_eq(sent.agent.input, "")
  assert_eq(sent.agent.state_text, "running")
  assert_eq(send_commands.length(), 1)
  match send_commands[0] {
    AgentSend(session_id, prompt) => {
      assert_eq(session_id, "ses_live")
      assert_eq(prompt, "continue the review")
    }
    _ => fail("expected AgentSend")
  }
  let (_, stop_commands) = update_full(sent, AgentStopSession)
  assert_eq(stop_commands.length(), 1)
  match stop_commands[0] {
    AgentStop(session_id) => assert_eq(session_id, "ses_live")
    _ => fail("expected AgentStop")
  }
  let (_, resume_commands) = update_full(sent, AgentResumeSession)
  assert_eq(resume_commands.length(), 1)
  match resume_commands[0] {
    AgentResume(session_id) => assert_eq(session_id, "ses_live")
    _ => fail("expected AgentResume")
  }
  let (streamed, _) = update_full(
    sent,
    AgentStreamText(42L, "the review is clean"),
  )
  assert_eq(streamed.agent.transcript, "the review is clean")
  assert_eq(streamed.agent.cursor, 42L)
}

///|
test "agent start uses selected names instead of typed ids" {
  let model = update(Model::new(), AgentSelect("planner"))
  let model = update(model, AgentWorkspaceSelect("wsp_1"))
  let model = update(model, AgentWorktree("wt_1"))
  let model = update(model, AgentPromptDraft("ship it"))
  let (next, commands) = update_full(model, AgentStartSession)
  assert_eq(next.agent.state_text, "starting")
  assert_eq(commands.length(), 1)
  match commands[0] {
    AgentStart(agent_id, mode, workspace_id, worktree_id, prompt) => {
      assert_eq(agent_id, "planner")
      assert_eq(mode, @contracts.AGENT_MODE_ACP)
      assert_eq(workspace_id, "wsp_1")
      assert_eq(worktree_id, "wt_1")
      assert_eq(prompt, "ship it")
    }
    _ => fail("expected AgentStart")
  }
}

///|
test "agent start rejects a blank selector" {
  let model = update(Model::new(), AgentId(""))
  let (next, commands) = update_full(model, AgentStartSession)
  assert_eq(commands.length(), 0)
  assert_true(next.agent.message.contains("select an agent"))
  let defaulted = update(next, AgentUseDefault)
  assert_eq(defaulted.agent.agent_id, "default")
  assert_true(defaulted.agent.message.contains("Default agent selected"))
}

///|
test "task create and dispatch preserve selected workspace and machine" {
  let custom = update(Model::new(), TaskWorkspaceSelect("wsp_custom"))
  let titled = update(custom, TaskTitle("ship input UX"))
  let (_, created) = update_full(titled, TaskCreateSubmit)
  assert_eq(created.length(), 1)
  match created[0] {
    TaskCreate(_, _, workspace_id, _) => assert_eq(workspace_id, "wsp_custom")
    _ => fail("expected TaskCreate")
  }
  let task = task_test_record("tsk_1", "ship input UX")
  let selected = update(Model::new(), TasksLoaded([task]))
  let selected = update(selected, TaskSelect("tsk_1"))
  let selected = update(selected, TaskMachineSelect("mch_remote"))
  let selected = update(selected, TaskCommand("moon test"))
  let (_, dispatched) = update_full(selected, RunDispatch)
  assert_eq(dispatched.length(), 1)
  match dispatched[0] {
    RunCreate(task_id, _, machine_id, workspace_id) => {
      assert_eq(task_id, "tsk_1")
      assert_eq(machine_id, "mch_remote")
      assert_eq(workspace_id, "wsp_1")
    }
    _ => fail("expected RunCreate")
  }
}

///|
test "copy id queues a native clipboard command and reports status" {
  let (copying, commands) = update_full(Model::new(), CopyId("Agent ID", "agent_1"))
  assert_eq(copying.clipboard_note, "Copying Agent ID...")
  assert_eq(commands.length(), 1)
  match commands[0] {
    CopyText(label, text) => {
      assert_eq(label, "Agent ID")
      assert_eq(text, "agent_1")
    }
    _ => fail("expected CopyText")
  }
  let copied = update(copying, ClipboardCopied(true, "Agent ID"))
  assert_eq(copied.clipboard_note, "Copied Agent ID")
  let unavailable = update(copying, ClipboardCopied(false, "Agent ID"))
  assert_true(unavailable.clipboard_note.contains("Clipboard unavailable"))
}

///|
test "rpc params carry the mandatory client_request_id" {
  let params = @app.rpc_params(
    "cmd_test", Map([("limit", @contracts.json_int(5))]),
  )
  assert_eq(@contracts.string_field_or(params, "id", ""), "cmd_test")
  assert_eq(@contracts.client_request_id(params), Some("cmd_test"))
  assert_eq(@contracts.int_field(params, "limit"), Some(5))
}

///|
test "selecting name-selector pages asks the worker for projections" {
  let (_, commands) = update_full(Model::new(), SelectPage(Projects))
  assert_eq(commands.length(), 2)
  match commands[0] {
    ProjectList => ()
    _ => fail("expected ProjectList")
  }
  match commands[1] {
    RefreshMachines => ()
    _ => fail("expected RefreshMachines")
  }
  let (_, agent_commands) = update_full(Model::new(), SelectPage(Agents))
  assert_eq(agent_commands.length(), 3)
  match agent_commands[2] {
    RefreshMachines => ()
    _ => fail("expected RefreshMachines for Agents")
  }
  let (_, task_commands) = update_full(Model::new(), SelectPage(Tasks))
  assert_eq(task_commands.length(), 3)
  match task_commands[2] {
    RefreshMachines => ()
    _ => fail("expected RefreshMachines for Tasks")
  }
}

///|
test "open workspace list sorts and restores a workspace by id" {
  let first : @contracts.WorkspaceRecord = {
    id: "wsp_1",
    machine_id: "",
    kind: "local",
    root: "/tmp/one",
    name: "one",
    git_root: "/tmp/one",
    is_git: true,
    state: "open",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
  let second : @contracts.WorkspaceRecord = {
    id: "wsp_2",
    machine_id: "mch_1",
    kind: "ssh",
    root: "/tmp/two",
    name: "two",
    git_root: "",
    is_git: false,
    state: "open",
    created_at: "2026-01-02T00:00:00Z",
    updated_at: "2026-01-02T00:00:00Z",
  }
  let model = update(Model::new(), ProjectWorkspaces([second, first]))
  assert_true(model.project.workspaces_loaded)
  assert_eq(model.project.workspaces[0].id, "wsp_1")
  assert_eq(model.project.workspaces[1].id, "wsp_2")
  let (restored, commands) = update_full(model, ProjectSelectWorkspace("wsp_2"))
  assert_eq(restored.project.root, "/tmp/two")
  assert_eq(restored.project.machine_id, "mch_1")
  assert_eq(commands.length(), 1)
  match commands[0] {
    OpenProject(machine_id, root) => {
      assert_eq(machine_id, "mch_1")
      assert_eq(root, "/tmp/two")
    }
    _ => fail("expected OpenProject")
  }
  let (_, missing) = update_full(model, ProjectSelectWorkspace("wsp_gone"))
  assert_eq(missing.length(), 0)
}

///|
test "project file load, edit and save cycle" {
  let record : @contracts.WorkspaceRecord = {
    id: "wsp_1",
    machine_id: "",
    kind: "local",
    root: "/tmp/demo",
    name: "demo",
    git_root: "/tmp/demo",
    is_git: true,
    state: "open",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
  let entries : Array[@contracts.WorkspaceEntry] = [
    { name: "src", path: "src", kind: "dir", is_dir: true, size: 0L },
    { name: "README.md", path: "README.md", kind: "file", is_dir: false, size: 12L },
  ]
  let model = update(Model::new(), ProjectOpened(record))
  let model = update(model, ProjectEntries(entries))
  assert_eq(model.project.entries[0].name, "src")
  assert_eq(model.project.entries[1].name, "README.md")
  let model = update(model, ProjectFile("README.md", "hello"))
  assert_eq(model.project.selected, "README.md")
  assert_eq(model.project.content, "hello")
  assert_true(!model.project.dirty)
  let model = update(model, ProjectDraft("hello world"))
  assert_true(model.project.dirty)
  let (saving, commands) = update_full(model, ProjectSaveFile)
  assert_true(saving.project.busy)
  assert_eq(commands.length(), 1)
  match commands[0] {
    ProjectWriteFile(workspace_id, path, content) => {
      assert_eq(workspace_id, "wsp_1")
      assert_eq(path, "README.md")
      assert_eq(content, "hello world")
    }
    _ => fail("expected ProjectWriteFile")
  }
}

///|
test "worktree create validates branch and path" {
  let record : @contracts.WorkspaceRecord = {
    id: "wsp_1",
    machine_id: "",
    kind: "local",
    root: "/tmp/demo",
    name: "demo",
    git_root: "/tmp/demo",
    is_git: true,
    state: "open",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
  let model = update(Model::new(), ProjectOpened(record))
  let (missing, commands) = update_full(model, ProjectCreateWorktree)
  assert_eq(commands.length(), 0)
  assert_true(missing.project.message.contains("branch and path"))
  let filled = update(
    update(model, ProjectWorktreeBranch("m3-test")),
    ProjectWorktreePath("/tmp/demo-wt"),
  )
  let (_, commands2) = update_full(filled, ProjectCreateWorktree)
  assert_eq(commands2.length(), 1)
  match commands2[0] {
    ProjectCreateWorktree(workspace_id, branch, path) => {
      assert_eq(workspace_id, "wsp_1")
      assert_eq(branch, "m3-test")
      assert_eq(path, "/tmp/demo-wt")
    }
    _ => fail("expected ProjectCreateWorktree")
  }
}

///|
fn task_test_record(id : String, title : String) -> @contracts.TaskRecord {
  @contracts.TaskRecord::new(
    id~,
    title~,
    goal="ship M5",
    parent_id="",
    project_id="",
    agent_id="",
    workspace_id="wsp_1",
    verify=["moon test"],
    created_at="2026-01-01T00:00:00Z",
  )
}

///|
test "task create picks the open project workspace and emits TaskCreate" {
  let record : @contracts.WorkspaceRecord = {
    id: "wsp_1",
    machine_id: "",
    kind: "local",
    root: "/tmp/demo",
    name: "demo",
    git_root: "/tmp/demo",
    is_git: true,
    state: "open",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
  let model = update(Model::new(), ProjectOpened(record))
  let (missing, none) = update_full(model, TaskCreateSubmit)
  assert_eq(none.length(), 0)
  assert_true(missing.task.message.contains("title is required"))
  let titled = update(model, TaskTitle("ship M5"))
  let verified = update(titled, TaskVerify("moon test\nmoon build"))
  let (next, commands) = update_full(verified, TaskCreateSubmit)
  assert_eq(commands.length(), 1)
  match commands[0] {
    TaskCreate(title, _, workspace_id, verify) => {
      assert_eq(title, "ship M5")
      assert_eq(workspace_id, "wsp_1")
      assert_eq(verify, "moon test\nmoon build")
    }
    _ => fail("expected TaskCreate")
  }
  assert_eq(next.task.workspace_id, "wsp_1")
}

///|
test "selecting a task refreshes runs and dispatch uses its workspace" {
  let task = task_test_record("tsk_1", "ship M5")
  let model = update(Model::new(), TasksLoaded([task]))
  let (selected, commands) = update_full(model, TaskSelect("tsk_1"))
  assert_eq(commands.length(), 1)
  match commands[0] {
    RunList(task_id) => assert_eq(task_id, "tsk_1")
    _ => fail("expected RunList")
  }
  let loaded = update(selected, EventsLoaded([], 0L))
  let (_, reload) = update_full(
    update(loaded, TaskCommand("moon test")),
    RunDispatch,
  )
  assert_eq(reload.length(), 1)
  match reload[0] {
    RunCreate(task_id, command, machine_id, workspace_id) => {
      assert_eq(task_id, "tsk_1")
      assert_eq(command, "moon test")
      assert_eq(machine_id, "")
      assert_eq(workspace_id, "wsp_1")
    }
    _ => fail("expected RunCreate")
  }
}

///|
test "event batches dedupe on seq and advance the cursor" {
  let first = @contracts.EventEnvelope::new(
    id="evt_1",
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_TASK_CREATED,
    ts="2026-01-01T00:00:00Z",
    subject="task/tsk_1",
    seq=1L,
    payload=@json.Json::empty_object(),
  )
  let second = @contracts.EventEnvelope::new(
    id="evt_2",
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_RUN_QUEUED,
    ts="2026-01-01T00:00:01Z",
    subject="run/run_1",
    seq=2L,
    payload=@json.Json::empty_object(),
  )
  let model = update(Model::new(), EventsLoaded([first, second], 2L))
  assert_eq(model.task.events.length(), 2)
  assert_eq(model.task.event_seq, 2L)
  let again = update(model, EventsLoaded([second], 2L))
  assert_eq(again.task.events.length(), 2)
  // A gap-free cursor is never moved backwards by a stale projection read.
  let stale = update(again, EventsLoaded([], 1L))
  assert_eq(stale.task.event_seq, 2L)
}

///|
test "search submit trims the query and stores hits with the backend" {
  let (empty, none) = update_full(Model::new(), SearchSubmit)
  assert_eq(none.length(), 0)
  assert_true(empty.search.message.contains("type a query"))
  let model = update(update(Model::new(), SearchQuery("  verify failed  ")), SearchSubmit)
  let (searching, commands) = update_full(model, SearchSubmit)
  assert_eq(commands.length(), 1)
  match commands[0] {
    SearchSessions(query) => assert_eq(query, "verify failed")
    _ => fail("expected SearchSessions")
  }
  assert_true(searching.search.message.contains("verify failed"))
  let hits : Array[@contracts.SearchHit] = [
    { kind: "decision", ref_id: "dec_1", title: "verify", ts: "t1", snippet: "waived" },
  ]
  let loaded = update(searching, SearchLoaded(hits, "like"))
  assert_eq(loaded.search.hits.length(), 1)
  assert_eq(loaded.search.backend, "like")
}

///|
test "inbox decisions flow from needs you to waiting and handled" {
  let pending = @contracts.DecisionRecord::new(
    id="dec_pending",
    kind=@contracts.DECISION_KIND_APPROVAL,
    title="Approve a high-risk command",
    detail="rm -rf build",
    session_id="",
    agent_id="",
    options=[
      @contracts.DecisionOption::new(
        option_id=@contracts.DECISION_OPTION_APPROVE,
        name="Approve once",
        kind="allow_once",
      ),
      @contracts.DecisionOption::new(
        option_id=@contracts.DECISION_OPTION_DENY,
        name="Deny",
        kind="reject_once",
      ),
    ],
    created_at="2026-01-01T00:00:00Z",
    run_id="run_1",
  )
  assert_eq(inbox_bucket_of(pending), @contracts.INBOX_NEEDS_YOU)
  // The host answers an approval: the Run returns to the queue, so the
  // Decision moves to Waiting while work continues.
  let waiting = {
    ..pending,
    status: @contracts.DECISION_STATUS_ANSWERED,
    option_id: @contracts.DECISION_OPTION_APPROVE,
    answered_by: "owner",
    answered_at: "2026-01-01T00:01:00Z",
    run_status: @contracts.RUN_STATUS_QUEUED,
  }
  assert_eq(inbox_bucket_of(waiting), @contracts.INBOX_WAITING)
  let handled = {
    ..waiting,
    run_status: @contracts.RUN_STATUS_SUCCEEDED,
  }
  assert_eq(inbox_bucket_of(handled), @contracts.INBOX_HANDLED)
  let recovery_retry = {
    ..pending,
    id: "dec_recovery",
    kind: @contracts.DECISION_KIND_RECOVERY,
    status: @contracts.DECISION_STATUS_ANSWERED,
    option_id: @contracts.DECISION_OPTION_RETRY,
    answered_by: "owner",
    run_status: @contracts.RUN_STATUS_RUNNING,
  }
  assert_eq(inbox_bucket_of(recovery_retry), @contracts.INBOX_WAITING)
  let model = update(
    Model::new(),
    InboxDecisions([pending, waiting, handled, recovery_retry]),
  )
  assert_eq(model.inbox.decisions.length(), 4)
  assert_true(model.inbox.message.contains("needs you: 1"))
  assert_true(model.inbox.message.contains("waiting: 2"))
  assert_true(model.inbox.message.contains("handled: 1"))
}

///|
test "the Settings appearance note describes persistence" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=1280.0,
    height=800.0,
  )
  harness.tap_text("Settings")
  assert_true(
    harness.has_text(
      "Applies immediately and is saved for future launches; MONEXUS_THEME picks the startup mode only until you choose one.",
    ),
  )
}

///|
test "Agents and Tasks use name selectors and hide raw ids by default" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=1280.0,
    height=800.0,
  )
  harness.tap_text("Agents")
  assert_true(harness.has_text("Agents / Sessions"))
  assert_true(harness.has_text("Agent: Default agent"))
  assert_true(harness.has_text("Workspace: Select a workspace"))
  assert_true(harness.has_text("Use default agent"))
  assert_true(harness.has_text("Follow-up prompt"))
  assert_true(harness.has_text("Start session"))
  assert_false(harness.has_text("Agent id override"))
  assert_false(harness.has_text("Workspace id override"))
  harness.tap_text("Advanced")
  assert_true(harness.has_text("Agent id override"))
  assert_true(harness.has_text("Workspace id override"))
  harness.tap_text("Tasks")
  assert_true(harness.has_text("Create task"))
  assert_true(harness.has_text("Workspace: Select a workspace"))
  assert_false(harness.has_text("Workspace id override"))
  assert_false(harness.has_text("Machine id override"))
  harness.tap_text("Advanced")
  assert_true(harness.has_text("Workspace id override"))
}
