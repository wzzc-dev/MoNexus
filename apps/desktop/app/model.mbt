///|
/// Five shell pages. M1 only switches between them; the content is a
/// placeholder for M2-M5 business screens.
#derive(Eq)
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
/// Localized navigation label. `label()` stays the stable English identifier
/// used by `MONEXUS_SCENE_PAGE` and tests; this is the one the shell paints.
pub fn Page::label_in(self : Page, lang : Lang) -> String {
  match self {
    Home => tr(lang, "Home", "主页")
    Machines => tr(lang, "Machines", "机器")
    Projects => tr(lang, "Projects", "项目")
    Agents => tr(lang, "Agents", "智能体")
    Inbox => tr(lang, "Inbox", "收件箱")
    Tasks => tr(lang, "Tasks", "任务")
    Search => tr(lang, "Search", "搜索")
    Settings => tr(lang, "Settings", "设置")
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
pub fn LinkState::label_in(self : LinkState, lang : Lang) -> String {
  match self {
    Connecting => tr(lang, "connecting", "连接中")
    Online => tr(lang, "online", "在线")
    Offline => tr(lang, "offline", "离线")
  }
}

///|
/// Snapshot of the host returned by `host.status`, mirrored into the UI.
pub(all) struct HostProjection {
  link : LinkState
  host_id : String
  version : String
  ws_url : String
  token_status : String
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
    token_status: "unknown (host not connected)",
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
  machine_picker_open : Bool
  advanced : Bool
  root : String
  workspace : @contracts.WorkspaceRecord?
  workspaces : Array[@contracts.WorkspaceRecord]
  workspaces_loaded : Bool
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
    machine_picker_open: false,
    advanced: false,
    root: "",
    workspace: None,
    workspaces: [],
    workspaces_loaded: false,
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
  agent_picker_open : Bool
  workspace_picker_open : Bool
  session_picker_open : Bool
  advanced : Bool
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
    agent_picker_open: false,
    workspace_picker_open: false,
    session_picker_open: false,
    advanced: false,
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
/// Inbox bucket for a Decision. The host enriches `inbox`; the fallback keeps
/// offline/test records on the same shared rule.
pub fn inbox_bucket_of(record : @contracts.DecisionRecord) -> String {
  if record.inbox != "" {
    record.inbox
  } else {
    @contracts.decision_inbox_bucket(
      record.status,
      record.kind,
      record.option_id,
      record.run_status,
    )
  }
}

///|
/// Inbox page: every Decision, grouped into Needs you / waiting / handled.
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
  workspace_picker_open : Bool
  machine_picker_open : Bool
  advanced : Bool
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
    workspace_picker_open: false,
    machine_picker_open: false,
    advanced: false,
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
  /// Appearance mode; seeded at startup from the saved choice, else
  /// MONEXUS_THEME, and flipped by the Settings page.
  theme_mode : ThemeMode
  /// Diagnostic from startup preference loading or the last save attempt;
  /// empty when nothing needs reporting.
  theme_note : String
  /// UI language; seeded at startup from the saved choice, else MONEXUS_LANG,
  /// and flipped by the Settings page.
  lang : Lang
  /// Diagnostic from startup language loading or the last save attempt; empty
  /// when nothing needs reporting.
  lang_note : String
  /// Key of the nav/row currently hovered, for hover washes on hand-painted
  /// rows (buttons carry their own hover styles).
  hover_row : String
  /// Bumped on every page switch so the body scroll view resets to the top.
  scroll_epoch : Int32
  /// Last clipboard action result, shown in the status bar. IDs are secondary
  /// metadata in this shell, so the copy affordance needs visible feedback.
  clipboard_note : String
}

///|
/// Environment-only constructor used by tests, screenshot scenes and callers
/// that do not have async file access. The desktop entry point builds the
/// model with `new_with_preferences(startup_theme(), startup_language())` so
/// saved Settings choices win over `MONEXUS_THEME`/`MONEXUS_LANG`.
pub fn Model::new() -> Model {
  Model::new_with_preferences(
    startup_theme_from_env(),
    startup_language_from_env(),
  )
}

///|
/// Appearance-only constructor for callers that read the theme preference but
/// keep the environment language.
pub fn Model::new_with_startup(startup : StartupTheme) -> Model {
  Model::new_with_preferences(startup, startup_language_from_env())
}

///|
pub fn Model::new_with_preferences(
  startup : StartupTheme,
  language : StartupLanguage,
) -> Model {
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
            version: @contracts.PRODUCT_VERSION,
            ws_url: "ws://127.0.0.1:0/ws",
            token_status: "present (host.json 0600, scene)",
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
    theme_mode: startup.mode,
    theme_note: startup.note,
    lang: language.language,
    lang_note: language.note,
    hover_row: "",
    scroll_epoch: 0,
    clipboard_note: "",
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
  token_status : String
  state_dir : String
  event_seq : Int64
}

///|
pub(all) enum Msg {
  SelectPage(Page)
  /// Appearance flip from the Settings segmented control; repaints and asks
  /// the preference worker to persist the explicit choice.
  SetTheme(ThemeMode)
  /// Result of persisting an explicit choice, shown on the Settings page when
  /// the write failed.
  ThemeChoiceStored(ThemeSaveStatus)
  /// UI language flip from the Settings segmented control; asks the preference
  /// worker to persist the explicit choice.
  SetLanguage(Lang)
  /// Result of persisting the language choice, shown on the Settings page when
  /// the write failed.
  LanguageStored(LanguageSaveStatus)
  /// Hover bookkeeping for hand-painted nav/list rows.
  HoverRow(String, Bool)
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
  ProjectMachineSelect(String)
  ProjectMachinePicker(Bool)
  ProjectMachineToggle
  ProjectAdvanced(Bool)
  ProjectOpened(@contracts.WorkspaceRecord)
  ProjectWorkspaces(Array[@contracts.WorkspaceRecord])
  ProjectSelectWorkspace(String)
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
  AgentSelect(String)
  AgentWorkspaceSelect(String)
  AgentPicker(Bool)
  AgentWorkspacePicker(Bool)
  AgentSessionPicker(Bool)
  AgentToggle
  AgentWorkspaceToggle
  AgentSessionToggle
  AgentAdvanced(Bool)
  AgentUseDefault
  AgentSelectSession(String)
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
  TaskWorkspaceSelect(String)
  TaskMachineSelect(String)
  TaskWorkspacePicker(Bool)
  TaskMachinePicker(Bool)
  TaskWorkspaceToggle
  TaskMachineToggle
  TaskAdvanced(Bool)
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
  // Secondary ID copy affordance and its status-bar feedback.
  CopyId(String, String)
  ClipboardCopied(Bool, String)
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
  ProjectList
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
  AgentRead(String)
  CopyText(String, String)
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
  machine_status_text_in(status, English)
}

///|
pub fn machine_status_text_in(status : String, lang : Lang) -> String {
  match status {
    @contracts.MACHINE_STATUS_ONLINE => tr(lang, "online", "在线")
    @contracts.MACHINE_STATUS_DEGRADED => tr(lang, "degraded", "降级")
    @contracts.MACHINE_STATUS_OFFLINE => tr(lang, "offline", "离线")
    _ => tr(lang, "unknown", "未知")
  }
}

///|
/// Token presence is desktop-local state (never the value itself), so its
/// labels follow the UI language instead of the host's protocol vocabulary.
pub fn token_status_text_in(status : String, lang : Lang) -> String {
  match status {
    "" | "unknown (host not connected)" =>
      tr(lang, "unknown (host not connected)", "未知（主机未连接）")
    "missing" => tr(lang, "missing", "缺失")
    "present (host.json, never displayed)" =>
      tr(lang, "present (host.json, never displayed)", "存在（host.json，从不显示）")
    "present (host.json 0600, scene)" =>
      tr(lang, "present (host.json 0600, scene)", "存在（host.json 0600，场景）")
    _ => status
  }
}

///|
pub fn machine_profile_summary(
  record : @contracts.MachineRecord,
) -> String {
  machine_profile_summary_in(record, English)
}

///|
pub fn machine_profile_summary_in(
  record : @contracts.MachineRecord,
  lang : Lang,
) -> String {
  match record.profile {
    Some(profile) =>
      profile.os +
      "/" +
      profile.arch +
      " · " +
      profile.max_parallel.to_string() +
      tr(lang, " cpus", " 核") +
      (if profile.has_docker { " · docker" } else { "" }) +
      (if profile.has_gui { tr(lang, " · gui", " · 图形界面") } else { "" })
    None => tr(lang, "not probed yet", "尚未探测")
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
fn workspace_before(
  left : @contracts.WorkspaceRecord,
  right : @contracts.WorkspaceRecord,
) -> Bool {
  if left.created_at != right.created_at {
    left.created_at < right.created_at
  } else {
    left.id < right.id
  }
}

///|
fn sort_workspaces(
  records : Array[@contracts.WorkspaceRecord],
) -> Array[@contracts.WorkspaceRecord] {
  let out : Array[@contracts.WorkspaceRecord] = []
  for record in records {
    out.push(record)
  }
  let mut index = 1
  while index < out.length() {
    let current = out[index]
    let mut position = index
    while position > 0 && workspace_before(current, out[position - 1]) {
      out[position] = out[position - 1]
      position = position - 1
    }
    out[position] = current
    index = index + 1
  }
  out
}

///|
fn workspace_by_id(
  records : Array[@contracts.WorkspaceRecord],
  workspace_id : String,
) -> @contracts.WorkspaceRecord? {
  for record in records {
    if record.id == workspace_id {
      return Some(record)
    }
  }
  None
}

///|
fn root_basename(root : String) -> String {
  let parts = root.trim_end().split("/")
  let mut name = ""
  for part in parts {
    if part != "" {
      name = part.to_owned()
    }
  }
  if name == "" {
    root
  } else {
    name
  }
}

///|
pub fn workspace_display_name(record : @contracts.WorkspaceRecord) -> String {
  if record.name != "" {
    record.name
  } else {
    root_basename(record.root)
  }
}

///|
pub fn machine_display_name(
  machines : Array[@contracts.MachineRecord],
  machine_id : String,
  lang : Lang,
) -> String {
  if machine_id == "" {
    return tr(lang, "Local machine", "本地机器")
  }
  for record in machines {
    if record.id == machine_id {
      return if record.name == "" {
        tr(lang, "Unnamed machine", "未命名机器")
      } else {
        record.name
      }
    }
  }
  tr(lang, "Machine unavailable", "机器不可用")
}

///|
pub fn workspace_choice_label(
  machines : Array[@contracts.MachineRecord],
  record : @contracts.WorkspaceRecord,
  lang : Lang,
) -> String {
  workspace_display_name(record) +
  " · " +
  machine_display_name(machines, record.machine_id, lang)
}

///|
fn workspace_recency(record : @contracts.WorkspaceRecord) -> String {
  if record.updated_at != "" {
    record.updated_at
  } else {
    record.created_at
  }
}

///|
fn most_recent_workspace(
  records : Array[@contracts.WorkspaceRecord],
) -> @contracts.WorkspaceRecord? {
  let mut best : @contracts.WorkspaceRecord? = None
  for record in records {
    let replace = match best {
      None => true
      Some(current) =>
        workspace_recency(record) > workspace_recency(current) ||
        (workspace_recency(record) == workspace_recency(current) &&
          record.id < current.id)
    }
    if replace {
      best = Some(record)
    }
  }
  best
}

///|
fn default_workspace_id(
  model : Model,
  records : Array[@contracts.WorkspaceRecord],
) -> String {
  match model.project.workspace {
    Some(record) => record.id
    None =>
      match most_recent_workspace(records) {
        Some(record) => record.id
        None => ""
      }
  }
}

///|
/// When host projections arrive, fill empty selectors with the current Project
/// or the most recently used workspace. Explicit selections are preserved.
fn apply_workspace_defaults(
  model : Model,
  records : Array[@contracts.WorkspaceRecord],
) -> Model {
  let default = default_workspace_id(model, records)
  if default == "" {
    return model
  }
  let agent_workspace = if model.agent.session is None &&
    model.agent.workspace_id == "" {
    default
  } else {
    model.agent.workspace_id
  }
  let task_workspace = if model.task.workspace_id == "" {
    default
  } else {
    model.task.workspace_id
  }
  {
    ..model,
    agent: { ..model.agent, workspace_id: agent_workspace },
    task: { ..model.task, workspace_id: task_workspace },
  }
}

///|
fn session_recency(record : @contracts.AgentSessionRecord) -> String {
  if record.updated_at != "" {
    record.updated_at
  } else {
    record.started_at
  }
}

///|
fn most_recent_session(
  records : Array[@contracts.AgentSessionRecord],
) -> @contracts.AgentSessionRecord? {
  let mut best : @contracts.AgentSessionRecord? = None
  for record in records {
    let replace = match best {
      None => true
      Some(current) =>
        session_recency(record) > session_recency(current) ||
        (session_recency(record) == session_recency(current) &&
          record.id < current.id)
    }
    if replace {
      best = Some(record)
    }
  }
  best
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
      {
        ..model,
        page,
        hover_row: "",
        scroll_epoch: model.scroll_epoch + 1,
      },
      match page {
        Agents => [AgentList, ProjectList, RefreshMachines]
        Inbox => [DecisionList("")]
        Projects => [ProjectList, RefreshMachines]
        Tasks => [TaskRefresh(model.task.event_seq), ProjectList, RefreshMachines]
        _ => none
      },
    )
    SetTheme(mode) => ({ ..model, theme_mode: mode }, none)
    ThemeChoiceStored(status) => (
      {
        ..model,
        theme_note: match status {
          ThemeSaveOk => ""
          ThemeSaveFailed(message) =>
            tr(model.lang, "Appearance not saved: ", "外观偏好未保存：") + message
        },
      },
      none,
    )
    SetLanguage(lang) => ({ ..model, lang }, none)
    LanguageStored(status) => (
      {
        ..model,
        lang_note: match status {
          LanguageSaveOk => ""
          LanguageSaveFailed(message) =>
            tr(model.lang, "Language not saved: ", "语言偏好未保存：") + message
        },
      },
      none,
    )
    HoverRow(key, hovered) => (
      {
        ..model,
        hover_row: if hovered {
          key
        } else if model.hover_row == key {
          ""
        } else {
          model.hover_row
        },
      },
      none,
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
        token_status: snapshot.token_status,
        state_dir: if snapshot.state_dir == "" {
          model.host.state_dir
        } else {
          snapshot.state_dir
        },
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
          {
            ..model,
            machine_message: tr(
              model.lang,
              "add failed: host is required",
              "添加失败：主机为必填项",
            ),
          },
          none,
        )
      } else if port <= 0 || port > 65_535 {
        (
          {
            ..model,
            machine_message: tr(
              model.lang,
              "add failed: port must be 1-65535",
              "添加失败：端口必须在 1-65535 之间",
            ),
          },
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
            machine_message: tr(model.lang, "adding ", "正在添加 ") + host + "...",
          },
          [AddMachine(next_draft)],
        )
      }
    }
    ProbeMachine(machine_id) => (
      {
        ..model,
        machine_busy: machine_id,
        machine_message: tr(model.lang, "probing ", "正在探测 ") +
        machine_id +
        "...",
      },
      [ProbeMachine(machine_id)],
    )
    RemoveMachine(machine_id) => (
      {
        ..model,
        machine_busy: machine_id,
        machine_message: tr(model.lang, "removing ", "正在移除 ") +
        machine_id +
        "...",
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
              message: tr(
                model.lang,
                "root is required (absolute path)",
                "根目录为必填项（绝对路径）",
              ),
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
              message: tr(model.lang, "opening ", "正在打开 ") + root + "...",
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
    ProjectMachineSelect(value) => (
      {
        ..model,
        project: {
          ..model.project,
          machine_id: value,
          machine_picker_open: false,
        },
      },
      none,
    )
    ProjectMachinePicker(open) => (
      {
        ..model,
        project: { ..model.project, machine_picker_open: open },
      },
      none,
    )
    ProjectMachineToggle => (
      {
        ..model,
        project: {
          ..model.project,
          machine_picker_open: !model.project.machine_picker_open,
        },
      },
      none,
    )
    ProjectAdvanced(open) => (
      { ..model, project: { ..model.project, advanced: open } },
      none,
    )
    ProjectOpened(record) => {
      let workspaces : Array[@contracts.WorkspaceRecord] = []
      let mut replaced = false
      for existing in model.project.workspaces {
        if existing.id == record.id {
          workspaces.push(record)
          replaced = true
        } else {
          workspaces.push(existing)
        }
      }
      if !replaced {
        workspaces.push(record)
      }
      let opened = {
        ..model,
        project: {
          ..model.project,
          workspace: Some(record),
          workspaces: sort_workspaces(workspaces),
          workspaces_loaded: true,
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
          message: tr(model.lang, "opened ", "已打开 ") + record.root,
        },
      }
      (apply_workspace_defaults(opened, opened.project.workspaces), none)
    }
    ProjectWorkspaces(records) => {
      let sorted = sort_workspaces(records)
      let loaded = {
        ..model,
        project: {
          ..model.project,
          workspaces: sorted,
          workspaces_loaded: true,
        },
      }
      (apply_workspace_defaults(loaded, sorted), none)
    }
    ProjectSelectWorkspace(workspace_id) =>
      match workspace_by_id(model.project.workspaces, workspace_id) {
        Some(record) => (
          {
            ..model,
            project: {
              ..model.project,
              machine_id: record.machine_id,
              root: record.root,
              busy: true,
              message: tr(model.lang, "restoring ", "正在恢复 ") +
              record.root +
              "...",
            },
          },
          [OpenProject(record.machine_id, record.root)],
        )
        None => (
          {
            ..model,
            project: {
              ..model.project,
              message: tr(model.lang, "workspace ", "工作区 ") +
              workspace_id +
              tr(model.lang, " is no longer open", " 已不再打开"),
            },
          },
          none,
        )
      }
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
            project: {
              ..model.project,
              busy: true,
              message: tr(model.lang, "listing...", "正在列出..."),
            },
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
          message: tr(model.lang, "reading ", "正在读取 ") + path + "...",
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
                  message: tr(
                    model.lang,
                    "select a file first",
                    "请先选择一个文件",
                  ),
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
                  message: tr(model.lang, "saving...", "正在保存..."),
                },
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
          {
            ..model,
            project: {
              ..model.project,
              message: tr(
                model.lang,
                "open a project first",
                "请先打开一个项目",
              ),
            },
          },
          none,
        )
      }
    ProjectRefresh =>
      match model.project.workspace {
        Some(record) => (
          {
            ..model,
            project: {
              ..model.project,
              busy: true,
              message: tr(model.lang, "refreshing...", "正在刷新..."),
            },
          },
          [
            ProjectList,
            ProjectListFiles(record.id, ""),
            ProjectGitStatus(record.id),
            ProjectListWorktrees(record.id),
          ],
        )
        None => (
          {
            ..model,
            project: {
              ..model.project,
              message: tr(
                model.lang,
                "refreshing projects...",
                "正在刷新项目...",
              ),
            },
          },
          [ProjectList],
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
          terminal_text: model.project.terminal_text +
          tr(model.lang, "$ terminal ready\n", "$ 终端已就绪\n"),
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
              project: {
                ..model.project,
                message: tr(
                  model.lang,
                  "open a project first",
                  "请先打开一个项目",
                ),
              },
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
                  message: tr(
                    model.lang,
                    "branch and path are required",
                    "分支和路径均为必填项",
                  ),
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
                  message: tr(
                    model.lang,
                    "creating worktree...",
                    "正在创建工作树...",
                  ),
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
          {
            ..model,
            project: {
              ..model.project,
              message: tr(
                model.lang,
                "open a project first",
                "请先打开一个项目",
              ),
            },
          },
          none,
        )
      }
    ProjectWorktreeCreated(record) => (
      {
        ..model,
        project: {
          ..model.project,
          busy: false,
          worktree_message: tr(model.lang, "worktree ready ", "工作树已就绪 ") +
          record.path,
          message: tr(model.lang, "worktree ", "工作树 ") +
          record.branch +
          tr(model.lang, " ready", " 已就绪"),
        },
      },
      none,
    )
    ProjectWorktrees(records) => (
      {
        ..model,
        project: {
          ..model.project,
          worktree_message: tr(model.lang, "worktrees: ", "工作树：") +
          records.length().to_string(),
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
    AgentSelect(value) => (
      {
        ..model,
        agent: {
          ..model.agent,
          agent_id: value,
          agent_picker_open: false,
        },
      },
      none,
    )
    AgentWorkspaceSelect(value) => (
      {
        ..model,
        agent: {
          ..model.agent,
          workspace_id: value,
          workspace_picker_open: false,
        },
      },
      none,
    )
    AgentPicker(open) => (
      {
        ..model,
        agent: { ..model.agent, agent_picker_open: open },
      },
      none,
    )
    AgentWorkspacePicker(open) => (
      {
        ..model,
        agent: { ..model.agent, workspace_picker_open: open },
      },
      none,
    )
    AgentSessionPicker(open) => (
      {
        ..model,
        agent: { ..model.agent, session_picker_open: open },
      },
      none,
    )
    AgentToggle => (
      {
        ..model,
        agent: {
          ..model.agent,
          agent_picker_open: !model.agent.agent_picker_open,
        },
      },
      none,
    )
    AgentWorkspaceToggle => (
      {
        ..model,
        agent: {
          ..model.agent,
          workspace_picker_open: !model.agent.workspace_picker_open,
        },
      },
      none,
    )
    AgentSessionToggle => (
      {
        ..model,
        agent: {
          ..model.agent,
          session_picker_open: !model.agent.session_picker_open,
        },
      },
      none,
    )
    AgentAdvanced(open) => (
      { ..model, agent: { ..model.agent, advanced: open } },
      none,
    )
    AgentUseDefault => (
      {
        ..model,
        agent: {
          ..model.agent,
          agent_id: "default",
          message: tr(
            model.lang,
            "Default agent selected. The host creates its home on first start.",
            "已选择默认智能体。主机将在首次启动时创建其主目录。",
          ),
        },
      },
      none,
    )
    AgentSelectSession(session_id) => {
      let mut selected : @contracts.AgentSessionRecord? = None
      for record in model.agent.sessions {
        if record.id == session_id {
          selected = Some(record)
        }
      }
      match selected {
        Some(record) =>
          (
            {
              ..model,
              agent: {
                ..model.agent,
                session: Some(record),
                agent_id: if record.agent_id == "" {
                  model.agent.agent_id
                } else {
                  record.agent_id
                },
                workspace_id: if record.workspace_id == "" {
                  model.agent.workspace_id
                } else {
                  record.workspace_id
                },
                worktree_id: record.worktree_id,
                transcript: "",
                cursor: 0L,
                state_text: record.state,
                stop_reason: record.stop_reason,
                pending_decision: "",
                session_picker_open: false,
                message: tr(model.lang, "reading transcript...", "正在读取对话..."),
              },
            },
            [AgentRead(record.id)],
          )
        None => (
          {
            ..model,
            agent: {
              ..model.agent,
              message: tr(
                model.lang,
                "that session is no longer listed",
                "该会话已不在列表中",
              ),
            },
          },
          none,
        )
      }
    }
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
          message: tr(model.lang, "probing ", "正在探测 ") +
          model.agent.agent_id +
          "...",
        },
      },
      [AgentProbe(model.agent.agent_id, model.agent.mode, "")],
    )
    AgentStartSession =>
      if model.agent.agent_id.trim() == "" {
        (
          {
            ..model,
            agent: {
              ..model.agent,
              message: tr(
                model.lang,
                "start failed: select an agent",
                "启动失败：请选择一个智能体",
              ),
            },
          },
          none,
        )
      } else {
        (
          {
            ..model,
            agent: {
              ..model.agent,
              transcript: "",
              cursor: 0L,
              pending_decision: "",
              state_text: "starting",
              stop_reason: "",
              message: tr(model.lang, "starting ", "正在启动 ") +
              model.agent.agent_id +
              "...",
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
      }
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
                  message: tr(model.lang, "prompt sent", "提示词已发送"),
                },
              },
              [AgentSend(record.id, model.agent.input)],
            )
          }
        None => (
          {
            ..model,
            agent: {
              ..model.agent,
              message: tr(
                model.lang,
                "start a session first",
                "请先启动一个会话",
              ),
            },
          },
          none,
        )
      }
    AgentStopSession =>
      match model.agent.session {
        Some(record) => (
          {
            ..model,
            agent: {
              ..model.agent,
              message: tr(model.lang, "stopping...", "正在停止..."),
            },
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
            agent: {
              ..model.agent,
              message: tr(model.lang, "resuming ", "正在恢复 ") +
              record.id +
              "...",
            },
          },
          [AgentResume(record.id)],
        )
        None => (
          {
            ..model,
            agent: {
              ..model.agent,
              message: tr(
                model.lang,
                "no session to resume",
                "没有可恢复的会话",
              ),
            },
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
          agent_id: if record.agent_id == "" {
            model.agent.agent_id
          } else {
            record.agent_id
          },
          workspace_id: if record.workspace_id == "" {
            model.agent.workspace_id
          } else {
            record.workspace_id
          },
          worktree_id: record.worktree_id,
          transcript: "",
          cursor: 0L,
          state_text: record.state,
          stop_reason: record.stop_reason,
          pending_decision: "",
          message: tr(model.lang, "session started · ", "会话已启动 · ") +
          record.mode +
          " · " +
          record.cwd,
        },
      },
      [AgentList],
    )
    AgentSessions(records) => {
      let mut agent : AgentState = {
        ..model.agent,
        sessions: records,
        message: tr(model.lang, "sessions: ", "会话数：") +
        records.length().to_string(),
      }
      let commands : Array[MachineCommand] = []
      if agent.session is None {
        match most_recent_session(records) {
          Some(record) => {
            agent = {
              ..agent,
              session: Some(record),
              agent_id: if record.agent_id == "" {
                agent.agent_id
              } else {
                record.agent_id
              },
              workspace_id: if record.workspace_id == "" {
                agent.workspace_id
              } else {
                record.workspace_id
              },
              worktree_id: record.worktree_id,
              transcript: "",
              cursor: 0L,
              state_text: record.state,
              stop_reason: record.stop_reason,
              pending_decision: "",
              session_picker_open: false,
              message: tr(
                model.lang,
                "loaded the most recent session",
                "已加载最近会话",
              ),
            }
            commands.push(AgentRead(record.id))
          }
          None => ()
        }
      }
      ({ ..model, agent }, commands)
    }
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
    InboxRefresh => (model, [DecisionList("")])
    InboxDecisions(records) => {
      let mut needs = 0
      let mut waiting = 0
      let mut handled = 0
      for record in records {
        let bucket = inbox_bucket_of(record)
        if bucket == @contracts.INBOX_NEEDS_YOU {
          needs = needs + 1
        } else if bucket == @contracts.INBOX_WAITING {
          waiting = waiting + 1
        } else {
          handled = handled + 1
        }
      }
      (
        {
          ..model,
          inbox: {
            ..model.inbox,
            decisions: records,
            message: tr(model.lang, "needs you: ", "需要你：") +
            needs.to_string() +
            tr(model.lang, " · waiting: ", " · 等待中：") +
            waiting.to_string() +
            tr(model.lang, " · handled: ", " · 已处理：") +
            handled.to_string(),
          },
        },
        none,
      )
    }
    InboxText(value) => (
      { ..model, inbox: { ..model.inbox, text: value } },
      none,
    )
    InboxAnswer(decision_id, option_id) => (
      {
        ..model,
        inbox: {
          ..model.inbox,
          message: tr(model.lang, "answering...", "正在回答..."),
        },
      },
      [
        DecisionRespond(decision_id, option_id, model.inbox.text, "owner"),
        DecisionList(""),
      ],
    )
    InboxSubmitText(decision_id) => (
      {
        ..model,
        inbox: {
          ..model.inbox,
          message: tr(
            model.lang,
            "answering with text...",
            "正在用文本回答...",
          ),
        },
      },
      [
        DecisionRespond(decision_id, "", model.inbox.text, "owner"),
        DecisionList(""),
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
    TaskWorkspaceSelect(value) => (
      {
        ..model,
        task: {
          ..model.task,
          workspace_id: value,
          workspace_picker_open: false,
        },
      },
      none,
    )
    TaskMachineSelect(value) => (
      {
        ..model,
        task: {
          ..model.task,
          machine_id: value,
          machine_picker_open: false,
        },
      },
      none,
    )
    TaskWorkspacePicker(open) => (
      {
        ..model,
        task: { ..model.task, workspace_picker_open: open },
      },
      none,
    )
    TaskMachinePicker(open) => (
      {
        ..model,
        task: { ..model.task, machine_picker_open: open },
      },
      none,
    )
    TaskWorkspaceToggle => (
      {
        ..model,
        task: {
          ..model.task,
          workspace_picker_open: !model.task.workspace_picker_open,
        },
      },
      none,
    )
    TaskMachineToggle => (
      {
        ..model,
        task: {
          ..model.task,
          machine_picker_open: !model.task.machine_picker_open,
        },
      },
      none,
    )
    TaskAdvanced(open) => (
      { ..model, task: { ..model.task, advanced: open } },
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
              message: tr(
                model.lang,
                "create failed: title is required",
                "创建失败：标题为必填项",
              ),
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
              message: tr(
                model.lang,
                "create failed: select a workspace or open a Project",
                "创建失败：请选择工作区或打开一个项目",
              ),
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
              message: tr(model.lang, "creating ", "正在创建 ") + title + "...",
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
          message: tr(model.lang, "selected ", "已选择 ") + task_id,
        },
      },
      [RunList(task_id)],
    )
    TaskCancelNow(task_id) => (
      {
        ..model,
        task: {
          ..model.task,
          message: tr(model.lang, "cancelling ", "正在取消 ") + task_id + "...",
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
            task: {
              ..model.task,
              message: tr(
                model.lang,
                "dispatch failed: select a task",
                "派发失败：请选择一个任务",
              ),
            },
          },
          none,
        )
      } else if state.command.trim() == "" {
        (
          {
            ..model,
            task: {
              ..model.task,
              message: tr(
                model.lang,
                "dispatch failed: command is empty",
                "派发失败：命令为空",
              ),
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
              message: tr(
                model.lang,
                "dispatch failed: task has no workspace",
                "派发失败：任务没有工作区",
              ),
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
              message: tr(model.lang, "dispatching on ", "正在派发到 ") +
                (if state.machine_id == "" {
                  tr(model.lang, "local", "本地")
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
          message: tr(model.lang, "opening ", "正在打开 ") + run_id + "...",
        },
      },
      [RunGet(run_id)],
    )
    RunCancelNow(run_id) => (
      {
        ..model,
        task: {
          ..model.task,
          message: tr(model.lang, "cancelling ", "正在取消 ") + run_id + "...",
        },
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
        task: {
          ..model.task,
          message: tr(model.lang, "reading artifact ", "正在读取产物 ") +
          artifact_id +
          "...",
        },
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
          message: tr(model.lang, "artifact loaded: ", "产物已加载：") + name,
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
    CopyId(label, id) => (
      {
        ..model,
        clipboard_note: tr(model.lang, "Copying ", "正在复制 ") +
        label +
        "...",
      },
      [CopyText(label, id)],
    )
    ClipboardCopied(ok, label) => (
      {
        ..model,
        clipboard_note: if ok {
          tr(model.lang, "Copied ", "已复制 ") + label
        } else {
          tr(
            model.lang,
            "Clipboard unavailable; select the text to copy manually: ",
            "剪贴板不可用；请手动选择复制：",
          ) +
          label
        },
      },
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
            search: {
              ..model.search,
              message: tr(
                model.lang,
                "type a query first",
                "请先输入查询内容",
              ),
            },
          },
          none,
        )
      } else {
        (
          {
            ..model,
            search: {
              ..model.search,
              message: tr(model.lang, "searching for ", "正在搜索 ") +
              query +
              "...",
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
