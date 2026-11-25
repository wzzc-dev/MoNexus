///|
test "the shell renders the header and the Home page" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=920.0,
    height=560.0,
  )
  assert_true(harness.has_text("MoNexus"))
  assert_true(harness.has_text("Welcome to MoNexus"))
  assert_true(harness.has_text("host connecting"))
}

///|
test "all eight pages can be switched by tapping navigation" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=920.0,
    height=560.0,
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
    width=920.0,
    height=560.0,
  )
  harness.tap_text("Projects")
  assert_true(harness.has_text("Open project"))
  assert_true(harness.has_text("No project open yet."))
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
