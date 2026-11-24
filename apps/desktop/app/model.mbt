///|
/// Five shell pages. M1 only switches between them; the content is a
/// placeholder for M2-M5 business screens.
pub(all) enum Page {
  Home
  Machines
  Projects
  Agents
  Inbox
  Tasks
  Search
  Settings
}

///|
pub fn Page::label(self : Page) -> String {
  match self {
    Home => "Home"
    Machines => "Machines"
    Projects => "Projects"
    Agents => "Agents"
    Inbox => "Inbox"
    Tasks => "Tasks"
    Search => "Search"
    Settings => "Settings"
  }
}

///|
pub fn Page::from_label(value : String) -> Page {
  match value.to_lower() {
    "machines" => Machines
    "projects" => Projects
    "agents" => Agents
    "inbox" => Inbox
    "tasks" => Tasks
    "search" => Search
    "settings" => Settings
    _ => Home
  }
}

///|
/// Connection state shown in the header and on the Home page.
pub(all) enum LinkState {
  Connecting
  Online
  Offline
}

///|
pub fn LinkState::label(self : LinkState) -> String {
  match self {
    Connecting => "connecting"
    Online => "online"
    Offline => "offline"
  }
}

///|
/// Snapshot of the host returned by `host.status`, mirrored into the UI.
pub(all) struct HostProjection {
  link : LinkState
  host_id : String
  version : String
  ws_url : String
  state_dir : String
  event_seq : Int64
  event_count : Int
  last_event : String
  last_error : String
}

///|
pub fn HostProjection::new(state_dir : String) -> HostProjection {
  {
    link: Connecting,
    host_id: "",
    version: "",
    ws_url: "",
    state_dir,
    event_seq: 0L,
    event_count: 0,
    last_event: "",
    last_error: "",
  }
}

///|
/// Editable fields of the `machine.add` form. `port` stays a string while the
/// user types; it is parsed and validated on submit.
pub(all) struct MachineDraft {
  name : String
  host : String
  port : String
  user : String
  identity : String
  known_hosts_file : String
  use_ssh_config : Bool
  host_key_policy : String
}

///|
pub fn MachineDraft::new() -> MachineDraft {
  {
    name: "",
    host: "",
    port: "22",
    user: "",
    identity: "",
    known_hosts_file: "",
    use_ssh_config: true,
    host_key_policy: @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
  }
}

///|
/// M3 Projects page state. The page never knows whether the workspace is
/// local or SSH: it only holds the machine id (`""` = local) and a root.
pub(all) struct ProjectState {
  machine_id : String
  root : String
  workspace : @contracts.WorkspaceRecord?
  entries : Array[@contracts.WorkspaceEntry]
  selected : String
  content : String
  dirty : Bool
  status_text : String
  diff_text : String
  terminal_id : String
  terminal_text : String
  terminal_input : String
  terminal_cursor : Int64
  worktree_branch : String
  worktree_path : String
  worktree_message : String
  busy : Bool
  message : String
}

///|
pub fn ProjectState::new() -> ProjectState {
  {
    machine_id: "",
    root: "",
    workspace: None,
    entries: [],
    selected: "",
    content: "",
    dirty: false,
    status_text: "",
    diff_text: "",
    terminal_id: "",
    terminal_text: "",
    terminal_input: "",
    terminal_cursor: 0L,
    worktree_branch: "",
    worktree_path: "",
    worktree_message: "",
    busy: false,
    message: "",
  }
}

///|
/// M4 Agents page: one live ACP session plus the owner's controls.
pub(all) struct AgentState {
  agent_id : String
  mode : String
  workspace_id : String
  worktree_id : String
  prompt : String
  input : String
  session : @contracts.AgentSessionRecord?
  sessions : Array[@contracts.AgentSessionRecord]
  transcript : String
  cursor : Int64
  state_text : String
  stop_reason : String
  pending_decision : String
  message : String
}

///|
pub fn AgentState::new() -> AgentState {
  {
    agent_id: "default",
    mode: @contracts.AGENT_MODE_ACP,
    workspace_id: "",
    worktree_id: "",
    prompt: "Reply with a short greeting.",
    input: "",
    session: None,
    sessions: [],
    transcript: "",
    cursor: 0L,
    state_text: "idle",
    stop_reason: "",
    pending_decision: "",
    message: "",
  }
}

///|
/// Inbox page: pending Decisions shared by permissions and readiness.
pub(all) struct InboxState {
  decisions : Array[@contracts.DecisionRecord]
  text : String
  message : String
}

///|
pub fn InboxState::new() -> InboxState {
  { decisions: [], text: "", message: "", }
}

///|
/// M5 Tasks board: the ready-to-dispatch create form, the task list, the
/// selected task's runs, one open Run detail (evidence, artifacts, diff) and
/// the tail of the host event stream.
pub(all) struct TaskState {
  title : String
  goal : String
  verify_text : String
  command : String
  workspace_id : String
  machine_id : String
  tasks : Array[@contracts.TaskRecord]
  selected_task : String
  runs : Array[@contracts.RunRecord]
  selected_run : String
  detail : @contracts.RunDetail?
  artifact_name : String
  artifact_text : String
  events : Array[@contracts.EventEnvelope]
  event_seq : Int64
  message : String
}

///|
pub fn TaskState::new() -> TaskState {
  {
    title: "",
    goal: "",
    verify_text: "",
    command: "moon test --target native",
    workspace_id: "",
    machine_id: "",
    tasks: [],
    selected_task: "",
    runs: [],
    selected_run: "",
    detail: None,
    artifact_name: "",
    artifact_text: "",
    events: [],
    event_seq: 0L,
    message: "",
  }
}

///|
/// M5 Search page: one query over session and decision text.
pub(all) struct SearchState {
  query : String
  hits : Array[@contracts.SearchHit]
  backend : String
  message : String
}

///|
pub fn SearchState::new() -> SearchState {
  { query: "", hits: [], backend: "", message: "" }
}

///|
pub struct Model {
  page : Page
  host : HostProjection
  machines : Array[@contracts.MachineRecord]
  machines_loaded : Bool
  machine_busy : String
  machine_message : String
  draft : MachineDraft
  project : ProjectState
  agent : AgentState
  inbox : InboxState
  task : TaskState
  search : SearchState
}

///|
pub fn Model::new() -> Model {
  let state_dir = @client.default_state_dir()
  let page = match @env.get_env_var("MONEXUS_SCENE_PAGE") {
    Some(value) => Page::from_label(value)
    None => Home
  }
  let mut host = HostProjection::new(state_dir)
  // Scene overrides let `moui screenshot` capture deterministic online and
  // offline states without a running host.
  match @env.get_env_var("MONEXUS_SCENE_HOST") {
    Some(value) =>
      match value.to_lower() {
        "online" => {
          host = {
            ..host,
            link: Online,
            host_id: "host_scene",
            version: "0.1.0-m1",
            ws_url: "ws://127.0.0.1:0/ws",
            event_seq: 3L,
            event_count: 3,
            last_event: "host.heartbeat",
          }
        }
        "offline" => {
          host = {
            ..host,
            link: Offline,
            last_error: "host.json not found (scene)",
          }
        }
        _ => ()
      }
    None => ()
  }
  let mut machines : Array[@contracts.MachineRecord] = []
  match @env.get_env_var("MONEXUS_SCENE_MACHINES") {
    Some(value) =>
      if value.to_lower() == "demo" {
        machines = [
          scene_machine(
            "mch_scene_online",
            "studio",
            @contracts.MACHINE_STATUS_ONLINE,
            "",
          ),
          scene_machine(
            "mch_scene_degraded",
            "builder",
            @contracts.MACHINE_STATUS_DEGRADED,
            "",
          ),
          scene_machine(
            "mch_scene_offline",
            "old-box",
            @contracts.MACHINE_STATUS_OFFLINE,
            "Unreachable: SSH connection failed",
          ),
        ]
      }
    None => ()
  }
  {
    page,
    host,
    machines,
    machines_loaded: machines.length() > 0,
    machine_busy: "",
    machine_message: "",
    draft: MachineDraft::new(),
    project: ProjectState::new(),
    agent: AgentState::new(),
    inbox: InboxState::new(),
    task: TaskState::new(),
    search: SearchState::new(),
  }
}

///|
fn scene_machine(
  id : String,
  name : String,
  status : String,
  last_error : String,
) -> @contracts.MachineRecord {
  let profile = if status == @contracts.MACHINE_STATUS_OFFLINE {
    None
  } else {
    Some(
      @contracts.MachineProfile::new(
        arch="x86_64",
        os="Linux",
        hostname=name,
        shell="/bin/zsh",
        toolchains=Map([("git", "/usr/bin/git"), ("moon", "/usr/bin/moon")]),
        has_docker=true,
        has_gui=false,
        max_parallel=16,
        notes="scene data",
      ),
    )
  }
  {
    id,
    kind: @contracts.MACHINE_KIND_SSH,
    name,
    host: "127.0.0.1",
    port: 2222,
    user: "demo",
    identity: "~/.ssh/id_ed25519",
    use_ssh_config: true,
    host_key_policy: @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    known_hosts_file: "",
    status,
    profile,
    ssh_effective: Map([("hostname", "127.0.0.1"), ("port", "2222")]),
    ssh_effective_error: "",
    last_seen: "2026-01-01T00:00:00Z",
    last_error,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
}

///|
pub(all) struct HostStatusSnapshot {
  host_id : String
  version : String
  ws_url : String
  event_seq : Int64
}

///|
pub(all) enum Msg {
  SelectPage(Page)
  LinkConnecting
  LinkOnline(HostStatusSnapshot)
  LinkOffline(String)
  EventArrived(String, Int64)
  // Machine page <-> command worker.
  MachinesLoaded(Array[@contracts.MachineRecord])
  MachineUpserted(@contracts.MachineRecord)
  MachineRemoved(String)
  MachineNotice(String)
  MachineError(String)
  DraftName(String)
  DraftHost(String)
  DraftPort(String)
  DraftUser(String)
  DraftIdentity(String)
  DraftKnownHosts(String)
  DraftUseConfig(Bool)
  DraftCleared
  CycleDraftPolicy
  SubmitMachine
  ProbeMachine(String)
  RemoveMachine(String)
  RefreshMachines
  // Projects page <-> command worker.
  ProjectOpen
  ProjectRoot(String)
  ProjectMachine(String)
  ProjectOpened(@contracts.WorkspaceRecord)
  ProjectEntries(Array[@contracts.WorkspaceEntry])
  ProjectFile(String, String)
  ProjectStatus(String)
  ProjectDiff(String)
  ProjectDraft(String)
  ProjectNotice(String)
  ProjectError(String)
  ProjectSelectFile(String)
  ProjectOpenDir(String)
  ProjectOpenFile(String)
  ProjectSaveFile
  ProjectRefresh
  ProjectRefreshDiff
  ProjectTerminalInput(String)
  ProjectTerminalOpened(String)
  ProjectTerminalOutput(Int64, String)
  ProjectTerminalSend
  ProjectWorktreeBranch(String)
  ProjectWorktreePath(String)
  ProjectCreateWorktree
  ProjectWorktreeCreated(@contracts.WorktreeRecord)
  ProjectWorktrees(Array[@contracts.WorktreeRecord])
  // Agents / Inbox.
  AgentId(String)
  AgentMode(String)
  AgentWorkspace(String)
  AgentWorktree(String)
  AgentPromptDraft(String)
  AgentInputDraft(String)
  AgentRefresh
  AgentProbeNow
  AgentStartSession
  AgentSendInput
  AgentStopSession
  AgentResumeSession
  AgentStarted(@contracts.AgentSessionRecord)
  AgentSessions(Array[@contracts.AgentSessionRecord])
  AgentStreamState(String, String, String, String)
  AgentStreamText(Int64, String)
  AgentNotice(String)
  AgentError(String)
  InboxRefresh
  InboxDecisions(Array[@contracts.DecisionRecord])
  InboxText(String)
  InboxAnswer(String, String)
  InboxSubmitText(String)
  // M5 Tasks board / Run detail / Activity.
  TaskTitle(String)
  TaskGoal(String)
  TaskVerify(String)
  TaskCommand(String)
  TaskWorkspace(String)
  TaskMachine(String)
  TaskCreateSubmit
  TasksRefresh
  TasksLoaded(Array[@contracts.TaskRecord])
  TaskSelect(String)
  TaskCancelNow(String)
  RunsLoaded(Array[@contracts.RunRecord])
  RunDispatch
  RunSelect(String)
  RunCancelNow(String)
  RunDetailLoaded(@contracts.RunDetail)
  ArtifactReadNow(String)
  ArtifactLoaded(String, String)
  EventsLoaded(Array[@contracts.EventEnvelope], Int64)
  TaskNotice(String)
  TaskError(String)
  // M5 Search.
  SearchQuery(String)
  SearchSubmit
  SearchLoaded(Array[@contracts.SearchHit], String)
}

///|
/// Side-effecting commands produced by `update_full`. The TEA update stays
/// pure; `program` turns these into an Effect that enqueues them for
/// `machine_command_loop`, which owns a separate RPC connection.
pub(all) enum MachineCommand {
  AddMachine(MachineDraft)
  ProbeMachine(String)
  RemoveMachine(String)
  RefreshMachines
  // Projects: open/list/read/write/diff/terminal/worktree all go through the
  // same host RPC surface, so the worker stays local/remote agnostic.
  OpenProject(String, String)
  ProjectListFiles(String, String)
  ProjectReadFile(String, String)
  ProjectWriteFile(String, String, String)
  ProjectGitStatus(String)
  ProjectGitDiff(String, String)
  ProjectOpenTerminal(String)
  ProjectTerminalWrite(String, String, Int64)
  ProjectTerminalRead(String)
  ProjectCloseTerminal(String)
  ProjectListWorktrees(String)
  ProjectCreateWorktree(String, String, String)
  // Agents / Inbox.
  AgentProbe(String, String, String)
  AgentStart(String, String, String, String, String)
  AgentSend(String, String)
  AgentStop(String)
  AgentResume(String)
  AgentList
  DecisionList(String)
  DecisionRespond(String, String, String, String)
  // M5 Tasks board, Run detail and Activity event cursor.
  TaskRefresh(Int64)
  TaskCreate(String, String, String, String)
  RunCreate(String, String, String, String)
  TaskCancel(String)
  RunList(String)
  RunGet(String)
  RunCancel(String)
  ArtifactRead(String)
  SearchSessions(String)
}

///|
fn machine_before(
  left : @contracts.MachineRecord,
  right : @contracts.MachineRecord,
) -> Bool {
  if left.created_at == right.created_at {
    left.id < right.id
  } else {
    left.created_at < right.created_at
  }
}

///|
fn sort_machines(machines : Array[@contracts.MachineRecord]) -> Unit {
  let mut index = 1
  while index < machines.length() {
    let current = machines[index]
    let mut position = index
    while position > 0 && machine_before(current, machines[position - 1]) {
      machines[position] = machines[position - 1]
      position = position - 1
    }
    machines[position] = current
    index = index + 1
  }
}

///|
fn machines_with(
  machines : Array[@contracts.MachineRecord],
  record : @contracts.MachineRecord,
) -> Array[@contracts.MachineRecord] {
  let out : Array[@contracts.MachineRecord] = []
  let mut replaced = false
  for existing in machines {
    if existing.id == record.id {
      out.push(record)
      replaced = true
    } else {
      out.push(existing)
    }
  }
  if !replaced {
    out.push(record)
  }
  sort_machines(out)
  out
}

///|
fn machines_without(
  machines : Array[@contracts.MachineRecord],
  machine_id : String,
) -> Array[@contracts.MachineRecord] {
  let out : Array[@contracts.MachineRecord] = []
  for existing in machines {
    if existing.id != machine_id {
      out.push(existing)
    }
  }
  out
}

///|
fn next_host_key_policy(policy : String) -> String {
  match policy {
    @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW =>
      @contracts.MACHINE_HOST_KEY_POLICY_STRICT
    @contracts.MACHINE_HOST_KEY_POLICY_STRICT =>
      @contracts.MACHINE_HOST_KEY_POLICY_INSECURE
    @contracts.MACHINE_HOST_KEY_POLICY_INSECURE =>
      @contracts.MACHINE_HOST_KEY_POLICY_CONFIG
    _ => @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW
  }
}

///|
pub fn machine_status_text(status : String) -> String {
  match status {
    @contracts.MACHINE_STATUS_ONLINE => "online"
    @contracts.MACHINE_STATUS_DEGRADED => "degraded"
    @contracts.MACHINE_STATUS_OFFLINE => "offline"
    _ => "unknown"
  }
}

///|
pub fn machine_profile_summary(
  record : @contracts.MachineRecord,
) -> String {
  match record.profile {
    Some(profile) =>
      profile.os +
      "/" +
      profile.arch +
      " · " +
      profile.max_parallel.to_string() +
      " cpus" +
      (if profile.has_docker { " · docker" } else { "" }) +
      (if profile.has_gui { " · gui" } else { "" })
    None => "not probed yet"
  }
}

///|
fn entry_before(
  left : @contracts.WorkspaceEntry,
  right : @contracts.WorkspaceEntry,
) -> Bool {
  if left.is_dir != right.is_dir {
    left.is_dir
  } else {
    left.name < right.name
  }
}

///|
pub fn sort_entries(
  entries : Array[@contracts.WorkspaceEntry],
) -> Array[@contracts.WorkspaceEntry] {
  let out : Array[@contracts.WorkspaceEntry] = []
  for entry in entries {
    out.push(entry)
  }
  let mut index = 1
  while index < out.length() {
    let current = out[index]
    let mut position = index
    while position > 0 && entry_before(current, out[position - 1]) {
      out[position] = out[position - 1]
      position = position - 1
    }
    out[position] = current
    index = index + 1
  }
  out
}

///|
/// Pure update: returns the next model plus the commands the command worker
/// should run. `update` below is the model-only view used by tests.
pub fn update_full(
  model : Model,
  msg : Msg,
) -> (Model, Array[MachineCommand]) {
  let none : Array[MachineCommand] = []
  match msg {
    SelectPage(page) => (
      { ..model, page },
      match page {
        Agents => [AgentList]
        Inbox => [DecisionList(@contracts.DECISION_STATUS_PENDING)]
        Tasks => [TaskRefresh(model.task.event_seq)]
        _ => none
      },
    )
    LinkConnecting => {
      let host = {
        ..model.host,
        link: Connecting,
        last_error: "",
      }
      ({ ..model, host }, none)
    }
    LinkOnline(snapshot) => {
      let host = {
        ..model.host,
        link: Online,
        host_id: snapshot.host_id,
        version: snapshot.version,
        ws_url: snapshot.ws_url,
        event_seq: snapshot.event_seq,
        last_error: "",
      }
      ({ ..model, host }, none)
    }
    LinkOffline(reason) => {
      let host = {
        ..model.host,
        link: Offline,
        last_error: reason,
      }
      ({ ..model, host }, none)
    }
    EventArrived(event_type, seq) => {
      let host = {
        ..model.host,
        event_seq: seq,
        event_count: model.host.event_count + 1,
        last_event: event_type,
      }
      // Task/Run/Artifact/Decision events keep the board and the Activity
      // list live; heartbeats and terminal chatter do not wake the worker.
      let relevant = event_type.has_prefix("task.") ||
        event_type.has_prefix("run.") ||
        event_type.has_prefix("artifact.") ||
        event_type.has_prefix("decision.") ||
        event_type.has_prefix("project.")
      let commands = if relevant {
        let since = if seq > 1L { seq - 1L } else { 0L }
        [TaskRefresh(since)]
      } else {
        none
      }
      ({ ..model, host }, commands)
    }
    MachinesLoaded(records) => {
      let machines : Array[@contracts.MachineRecord] = []
      for record in records {
        machines.push(record)
      }
      sort_machines(machines)
      ({ ..model, machines, machines_loaded: true }, none)
    }
    MachineUpserted(record) => (
      {
        ..model,
        machines: machines_with(model.machines, record),
        machines_loaded: true,
      },
      none,
    )
    MachineRemoved(machine_id) => (
      { ..model, machines: machines_without(model.machines, machine_id) },
      none,
    )
    MachineNotice(text) => (
      { ..model, machine_message: text, machine_busy: "" },
      none,
    )
    MachineError(text) => (
      { ..model, machine_message: text, machine_busy: "" },
      none,
    )
    DraftName(value) => (
      { ..model, draft: { ..model.draft, name: value } },
      none,
    )
    DraftHost(value) => (
      { ..model, draft: { ..model.draft, host: value } },
      none,
    )
    DraftPort(value) => (
      { ..model, draft: { ..model.draft, port: value } },
      none,
    )
    DraftUser(value) => (
      { ..model, draft: { ..model.draft, user: value } },
      none,
    )
    DraftIdentity(value) => (
      { ..model, draft: { ..model.draft, identity: value } },
      none,
    )
    DraftKnownHosts(value) => (
      { ..model, draft: { ..model.draft, known_hosts_file: value } },
      none,
    )
    DraftUseConfig(value) => (
      { ..model, draft: { ..model.draft, use_ssh_config: value } },
      none,
    )
    DraftCleared => (
      {
        ..model,
        draft: MachineDraft::new(),
        machine_busy: "",
      },
      none,
    )
    CycleDraftPolicy => (
      {
        ..model,
        draft: {
          ..model.draft,
          host_key_policy: next_host_key_policy(model.draft.host_key_policy),
        },
      },
      none,
    )
    SubmitMachine => {
      let draft = model.draft
      let host = draft.host.trim().to_owned()
      let port = @string.parse_int(draft.port.trim().to_owned()) catch {
        _ => 0
      }
      if host == "" {
        (
          { ..model, machine_message: "add failed: host is required" },
          none,
        )
      } else if port <= 0 || port > 65_535 {
        (
          { ..model, machine_message: "add failed: port must be 1-65535" },
          none,
        )
      } else {
        let name = if draft.name.trim() == "" {
          host
        } else {
          draft.name
        }
        let next_draft = { ..draft, name, host }
        (
          {
            ..model,
            draft: next_draft,
            machine_busy: "add",
            machine_message: "adding " + host + "...",
          },
          [AddMachine(next_draft)],
        )
      }
    }
    ProbeMachine(machine_id) => (
      {
        ..model,
        machine_busy: machine_id,
        machine_message: "probing " + machine_id + "...",
      },
      [ProbeMachine(machine_id)],
    )
    RemoveMachine(machine_id) => (
      {
        ..model,
        machine_busy: machine_id,
        machine_message: "removing " + machine_id + "...",
      },
      [RemoveMachine(machine_id)],
    )
    RefreshMachines => ({ ..model, machine_message: "" }, [RefreshMachines])
    ProjectOpen => {
      let root = model.project.root.trim().to_owned()
      if root == "" {
        (
          {
            ..model,
            project: {
              ..model.project,
              message: "root is required (absolute path)",
            },
          },
          none,
        )
      } else {
        (
          {
            ..model,
            project: {
              ..model.project,
              root,
              busy: true,
              message: "opening " + root + "...",
            },
          },
          [OpenProject(model.project.machine_id, root)],
        )
      }
    }
    ProjectRoot(value) => (
      { ..model, project: { ..model.project, root: value } },
      none,
    )
    ProjectMachine(value) => (
      { ..model, project: { ..model.project, machine_id: value } },
      none,
    )
    ProjectOpened(record) => (
      {
        ..model,
        project: {
          ..model.project,
          workspace: Some(record),
          entries: [],
          selected: "",
          content: "",
          dirty: false,
          status_text: "",
          diff_text: "",
          terminal_id: "",
          terminal_text: "",
          terminal_cursor: 0L,
          busy: false,
          message: "opened " + record.root,
        },
      },
      none,
    )
    ProjectEntries(entries) => (
      {
        ..model,
        project: {
          ..model.project,
          entries: sort_entries(entries),
          busy: false,
        },
      },
      none,
    )
    ProjectFile(path, content) => (
      {
        ..model,
        project: {
          ..model.project,
          selected: path,
          content,
          dirty: false,
          busy: false,
        },
      },
      none,
    )
    ProjectStatus(text) => (
      { ..model, project: { ..model.project, status_text: text } },
      none,
    )
    ProjectDiff(text) => (
      { ..model, project: { ..model.project, diff_text: text } },
      none,
    )
    ProjectDraft(content) => (
      {
        ..model,
        project: { ..model.project, content, dirty: true },
      },
      none,
    )
    ProjectNotice(text) => (
      {
        ..model,
        project: { ..model.project, message: text, busy: false },
      },
      none,
    )
    ProjectError(text) => (
      {
        ..model,
        project: { ..model.project, message: text, busy: false },
      },
      none,
    )
    ProjectSelectFile(path) => (
      {
        ..model,
        project: {
          ..model.project,
          selected: path,
          content: "",
          dirty: false,
          diff_text: "",
        },
      },
      none,
    )
    ProjectOpenDir(path) =>
      match model.project.workspace {
        Some(record) => (
          {
            ..model,
            project: { ..model.project, busy: true, message: "listing..." },
          },
          [ProjectListFiles(record.id, path)],
        )
        None => (model, none)
      }
    ProjectOpenFile(path) => (
      {
        ..model,
        project: {
          ..model.project,
          selected: path,
          content: "",
          dirty: false,
          diff_text: "",
          busy: true,
          message: "reading " + path + "...",
        },
      },
      match model.project.workspace {
        Some(record) => [ProjectReadFile(record.id, path)]
        None => none
      },
    )
    ProjectSaveFile =>
      match model.project.workspace {
        Some(record) =>
          if model.project.selected == "" {
            (
              {
                ..model,
                project: {
                  ..model.project,
                  message: "select a file first",
                },
              },
              none,
            )
          } else {
            (
              {
                ..model,
                project: { ..model.project, busy: true, message: "saving..." },
              },
              [
                ProjectWriteFile(
                  record.id,
                  model.project.selected,
                  model.project.content,
                ),
              ],
            )
          }
        None => (
          { ..model, project: { ..model.project, message: "open a project first" } },
          none,
        )
      }
    ProjectRefresh =>
      match model.project.workspace {
        Some(record) => (
          {
            ..model,
            project: { ..model.project, busy: true, message: "refreshing..." },
          },
          [
            ProjectListFiles(record.id, ""),
            ProjectGitStatus(record.id),
            ProjectListWorktrees(record.id),
          ],
        )
        None => (
          { ..model, project: { ..model.project, message: "open a project first" } },
          none,
        )
      }
    ProjectRefreshDiff =>
      match model.project.workspace {
        Some(record) =>
          if model.project.selected == "" {
            (model, none)
          } else {
            (
              model,
              [ProjectGitDiff(record.id, model.project.selected)],
            )
          }
        None => (model, none)
      }
    ProjectTerminalInput(value) => (
      { ..model, project: { ..model.project, terminal_input: value } },
      none,
    )
    ProjectTerminalOpened(terminal_id) => (
      {
        ..model,
        project: {
          ..model.project,
          terminal_id,
          terminal_text: model.project.terminal_text + "$ terminal ready\n",
          busy: false,
        },
      },
      none,
    )
    ProjectTerminalOutput(cursor, text) => (
      {
        ..model,
        project: {
          ..model.project,
          terminal_cursor: cursor,
          terminal_text: model.project.terminal_text + text,
        },
      },
      none,
    )
    ProjectTerminalSend => {
      let line = model.project.terminal_input
      if model.project.terminal_id != "" {
        (
          {
            ..model,
            project: { ..model.project, terminal_input: "", busy: true },
          },
          [
            ProjectTerminalWrite(
              model.project.terminal_id,
              line,
              model.project.terminal_cursor,
            ),
          ],
        )
      } else {
        match model.project.workspace {
          Some(record) => (
            {
              ..model,
              project: { ..model.project, busy: true },
            },
            [ProjectOpenTerminal(record.id)],
          )
          None => (
            {
              ..model,
              project: { ..model.project, message: "open a project first" },
            },
            none,
          )
        }
      }
    }
    ProjectWorktreeBranch(value) => (
      {
        ..model,
        project: { ..model.project, worktree_branch: value },
      },
      none,
    )
    ProjectWorktreePath(value) => (
      { ..model, project: { ..model.project, worktree_path: value } },
      none,
    )
    ProjectCreateWorktree =>
      match model.project.workspace {
        Some(record) =>
          if model.project.worktree_branch == "" ||
            model.project.worktree_path == "" {
            (
              {
                ..model,
                project: {
                  ..model.project,
                  message: "branch and path are required",
                },
              },
              none,
            )
          } else {
            (
              {
                ..model,
                project: {
                  ..model.project,
                  busy: true,
                  message: "creating worktree...",
                },
              },
              [
                ProjectCreateWorktree(
                  record.id,
                  model.project.worktree_branch,
                  model.project.worktree_path,
                ),
              ],
            )
          }
        None => (
          { ..model, project: { ..model.project, message: "open a project first" } },
          none,
        )
      }
    ProjectWorktreeCreated(record) => (
      {
        ..model,
        project: {
          ..model.project,
          busy: false,
          worktree_message: "worktree ready " + record.path,
          message: "worktree " + record.branch + " ready",
        },
      },
      none,
    )
    ProjectWorktrees(records) => (
      {
        ..model,
        project: {
          ..model.project,
          worktree_message: "worktrees: " + records.length().to_string(),
        },
      },
      none,
    )
    AgentId(value) => (
      { ..model, agent: { ..model.agent, agent_id: value } },
      none,
    )
    AgentMode(value) => (
      { ..model, agent: { ..model.agent, mode: value } },
      none,
    )
    AgentWorkspace(value) => (
      { ..model, agent: { ..model.agent, workspace_id: value } },
      none,
    )
    AgentWorktree(value) => (
      { ..model, agent: { ..model.agent, worktree_id: value } },
      none,
    )
    AgentPromptDraft(value) => (
      { ..model, agent: { ..model.agent, prompt: value } },
      none,
    )
    AgentInputDraft(value) => (
      { ..model, agent: { ..model.agent, input: value } },
      none,
    )
    AgentRefresh => (model, [AgentList])
    AgentProbeNow => (
      {
        ..model,
        agent: {
          ..model.agent,
          message: "probing " + model.agent.agent_id + "...",
        },
      },
      [AgentProbe(model.agent.agent_id, model.agent.mode, "")],
    )
    AgentStartSession => (
      {
        ..model,
        agent: {
          ..model.agent,
          transcript: "",
          cursor: 0L,
          pending_decision: "",
          state_text: "starting",
          stop_reason: "",
          message: "starting " + model.agent.agent_id + "...",
        },
      },
      [
        AgentStart(
          model.agent.agent_id,
          model.agent.mode,
          model.agent.workspace_id,
          model.agent.worktree_id,
          model.agent.prompt,
        ),
      ],
    )
    AgentSendInput =>
      match model.agent.session {
        Some(record) =>
          if model.agent.input == "" {
            (model, none)
          } else {
            (
              {
                ..model,
                agent: {
                  ..model.agent,
                  input: "",
                  state_text: "running",
                  message: "prompt sent",
                },
              },
              [AgentSend(record.id, model.agent.input)],
            )
          }
        None => (
          {
            ..model,
            agent: { ..model.agent, message: "start a session first" },
          },
          none,
        )
      }
    AgentStopSession =>
      match model.agent.session {
        Some(record) => (
          {
            ..model,
            agent: { ..model.agent, message: "stopping..." },
          },
          [AgentStop(record.id)],
        )
        None => (model, none)
      }
    AgentResumeSession =>
      match model.agent.session {
        Some(record) => (
          {
            ..model,
            agent: { ..model.agent, message: "resuming " + record.id + "..." },
          },
          [AgentResume(record.id)],
        )
        None => (
          {
            ..model,
            agent: { ..model.agent, message: "no session to resume" },
          },
          none,
        )
      }
    AgentStarted(record) => (
      {
        ..model,
        agent: {
          ..model.agent,
          session: Some(record),
          transcript: "",
          cursor: 0L,
          state_text: record.state,
          stop_reason: record.stop_reason,
          pending_decision: "",
          message:
            "session " +
            record.id +
            " · " +
            record.mode +
            " · " +
            record.cwd,
        },
      },
      [AgentList],
    )
    AgentSessions(records) => (
      {
        ..model,
        agent: {
          ..model.agent,
          sessions: records,
          message: "sessions: " + records.length().to_string(),
        },
      },
      none,
    )
    AgentStreamState(session_id, state, stop_reason, pending) => {
      let current = model.agent.session
      let same = match current {
        Some(record) => record.id == session_id
        None => false
      }
      (
        {
          ..model,
          agent: {
            ..model.agent,
            state_text: if same { state } else { model.agent.state_text },
            stop_reason: if same {
              stop_reason
            } else {
              model.agent.stop_reason
            },
            pending_decision: if same {
              pending
            } else {
              model.agent.pending_decision
            },
          },
        },
        none,
      )
    }
    AgentStreamText(cursor, text) => (
      {
        ..model,
        agent: {
          ..model.agent,
          cursor,
          transcript: model.agent.transcript + text,
        },
      },
      none,
    )
    AgentNotice(text) => (
      { ..model, agent: { ..model.agent, message: text } },
      none,
    )
    AgentError(text) => (
      { ..model, agent: { ..model.agent, message: text } },
      none,
    )
    InboxRefresh => (model, [DecisionList(@contracts.DECISION_STATUS_PENDING)])
    InboxDecisions(records) => (
      {
        ..model,
        inbox: {
          ..model.inbox,
          decisions: records,
          message: "pending decisions: " + records.length().to_string(),
        },
      },
      none,
    )
    InboxText(value) => (
      { ..model, inbox: { ..model.inbox, text: value } },
      none,
    )
    InboxAnswer(decision_id, option_id) => (
      {
        ..model,
        inbox: { ..model.inbox, message: "answering..." },
      },
      [
        DecisionRespond(decision_id, option_id, model.inbox.text, "owner"),
        DecisionList(@contracts.DECISION_STATUS_PENDING),
      ],
    )
    InboxSubmitText(decision_id) => (
      {
        ..model,
        inbox: { ..model.inbox, message: "answering with text..." },
      },
      [
        DecisionRespond(decision_id, "", model.inbox.text, "owner"),
        DecisionList(@contracts.DECISION_STATUS_PENDING),
      ],
    )
    TaskTitle(value) => (
      { ..model, task: { ..model.task, title: value } },
      none,
    )
    TaskGoal(value) => (
      { ..model, task: { ..model.task, goal: value } },
      none,
    )
    TaskVerify(value) => (
      { ..model, task: { ..model.task, verify_text: value } },
      none,
    )
    TaskCommand(value) => (
      { ..model, task: { ..model.task, command: value } },
      none,
    )
    TaskWorkspace(value) => (
      { ..model, task: { ..model.task, workspace_id: value } },
      none,
    )
    TaskMachine(value) => (
      { ..model, task: { ..model.task, machine_id: value } },
      none,
    )
    TaskCreateSubmit => {
      let state = model.task
      let title = state.title.trim().to_owned()
      let workspace_id = if state.workspace_id.trim() == "" {
        match model.project.workspace {
          Some(record) => record.id
          None => ""
        }
      } else {
        state.workspace_id
      }
      if title == "" {
        (
          {
            ..model,
            task: {
              ..model.task,
              message: "create failed: title is required",
            },
          },
          none,
        )
      } else if workspace_id.trim() == "" {
        (
          {
            ..model,
            task: {
              ..model.task,
              workspace_id,
              message: "create failed: open a Project or paste a workspace id",
            },
          },
          none,
        )
      } else {
        (
          {
            ..model,
            task: {
              ..model.task,
              workspace_id,
              message: "creating " + title + "...",
            },
          },
          [TaskCreate(title, state.goal, workspace_id, state.verify_text)],
        )
      }
    }
    TasksRefresh => (model, [TaskRefresh(model.task.event_seq)])
    TasksLoaded(records) => {
      let mut selected = ""
      for record in records {
        if record.id == model.task.selected_task {
          selected = record.id
        }
      }
      let commands = if selected == "" {
        none
      } else {
        [RunList(selected)]
      }
      (
        {
          ..model,
          task: {
            ..model.task,
            tasks: records,
            selected_task: selected,
            runs: if selected == "" { [] } else { model.task.runs },
            selected_run: if selected == "" {
              ""
            } else {
              model.task.selected_run
            },
            detail: if selected == "" { None } else { model.task.detail },
          },
        },
        commands,
      )
    }
    TaskSelect(task_id) => (
      {
        ..model,
        task: {
          ..model.task,
          selected_task: task_id,
          runs: [],
          selected_run: "",
          detail: None,
          artifact_name: "",
          artifact_text: "",
          message: "selected " + task_id,
        },
      },
      [RunList(task_id)],
    )
    TaskCancelNow(task_id) => (
      {
        ..model,
        task: {
          ..model.task,
          message: "cancelling " + task_id + "...",
        },
      },
      [TaskCancel(task_id)],
    )
    RunsLoaded(records) => {
      let mut selected_run = ""
      for record in records {
        if record.id == model.task.selected_run {
          selected_run = record.id
        }
      }
      let commands : Array[MachineCommand] = []
      if selected_run != "" {
        commands.push(RunGet(selected_run))
      }
      (
        {
          ..model,
          task: {
            ..model.task,
            runs: records,
            selected_run,
            detail: if selected_run == "" { None } else { model.task.detail },
          },
        },
        commands,
      )
    }
    RunDispatch => {
      let state = model.task
      let mut workspace_id = state.workspace_id
      let mut found = false
      for record in state.tasks {
        if record.id == state.selected_task {
          found = true
          if record.workspace_id != "" {
            workspace_id = record.workspace_id
          }
        }
      }
      if !found {
        (
          {
            ..model,
            task: { ..model.task, message: "dispatch failed: select a task" },
          },
          none,
        )
      } else if state.command.trim() == "" {
        (
          {
            ..model,
            task: { ..model.task, message: "dispatch failed: command is empty" },
          },
          none,
        )
      } else if workspace_id.trim() == "" {
        (
          {
            ..model,
            task: {
              ..model.task,
              message: "dispatch failed: task has no workspace",
            },
          },
          none,
        )
      } else {
        (
          {
            ..model,
            task: {
              ..model.task,
              message: "dispatching on " +
                (if state.machine_id == "" {
                  "local"
                } else {
                  state.machine_id
                }) +
                "...",
            },
          },
          [
            RunCreate(
              state.selected_task,
              state.command,
              state.machine_id,
              workspace_id,
            ),
          ],
        )
      }
    }
    RunSelect(run_id) => (
      {
        ..model,
        task: {
          ..model.task,
          selected_run: run_id,
          detail: None,
          artifact_name: "",
          artifact_text: "",
          message: "opening " + run_id + "...",
        },
      },
      [RunGet(run_id)],
    )
    RunCancelNow(run_id) => (
      {
        ..model,
        task: { ..model.task, message: "cancelling " + run_id + "..." },
      },
      [RunCancel(run_id)],
    )
    RunDetailLoaded(detail) => (
      {
        ..model,
        task: {
          ..model.task,
          detail: Some(detail),
          message:
            "run " +
            detail.run.id +
            " · " +
            detail.run.status +
            " · evidence " +
            detail.evidence.length().to_string() +
            " · artifacts " +
            detail.artifacts.length().to_string(),
        },
      },
      none,
    )
    ArtifactReadNow(artifact_id) => (
      {
        ..model,
        task: { ..model.task, message: "reading artifact " + artifact_id + "..." },
      },
      [ArtifactRead(artifact_id)],
    )
    ArtifactLoaded(name, text) => (
      {
        ..model,
        task: {
          ..model.task,
          artifact_name: name,
          artifact_text: text,
          message: "artifact loaded: " + name,
        },
      },
      none,
    )
    EventsLoaded(new_events, next_seq) => {
      let merged : Array[@contracts.EventEnvelope] = []
      let mut last : Int64 = 0L
      for event in model.task.events {
        merged.push(event)
        if event.seq > last {
          last = event.seq
        }
      }
      for event in new_events {
        if event.seq > last {
          merged.push(event)
          last = event.seq
        }
      }
      let trimmed : Array[@contracts.EventEnvelope] = []
      let skip = if merged.length() > 200 {
        merged.length() - 200
      } else {
        0
      }
      let mut index = 0
      for event in merged {
        if index >= skip {
          trimmed.push(event)
        }
        index = index + 1
      }
      let cursor = if next_seq > model.task.event_seq {
        next_seq
      } else {
        model.task.event_seq
      }
      (
        { ..model, task: { ..model.task, events: trimmed, event_seq: cursor } },
        none,
      )
    }
    TaskNotice(text) => (
      { ..model, task: { ..model.task, message: text } },
      none,
    )
    TaskError(text) => (
      { ..model, task: { ..model.task, message: text } },
      none,
    )
    SearchQuery(value) => (
      { ..model, search: { ..model.search, query: value } },
      none,
    )
    SearchSubmit => {
      let query = model.search.query.trim().to_owned()
      if query == "" {
        (
          {
            ..model,
            search: { ..model.search, message: "type a query first" },
          },
          none,
        )
      } else {
        (
          {
            ..model,
            search: {
              ..model.search,
              message: "searching for " + query + "...",
            },
          },
          [SearchSessions(query)],
        )
      }
    }
    SearchLoaded(hits, backend) => (
      {
        ..model,
        search: {
          ..model.search,
          hits,
          backend,
          message:
            "hits: " +
            hits.length().to_string() +
            (if backend == "" { "" } else { " · backend " + backend }),
        },
      },
      none,
    )
  }
}

///|
pub fn update(model : Model, msg : Msg) -> Model {
  let (next, _) = update_full(model, msg)
  next
}
