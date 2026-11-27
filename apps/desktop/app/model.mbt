///|
/// Primary desktop destinations. Chat is the opening surface; the Bot page is
/// reached from a Bot/Chat identity and is deliberately not a nav item.
#derive(Eq)
pub(all) enum Page {
  Workroom
  BotDetail
  Inbox
  Tasks
  Manage
  Search
  Settings
}

///|
pub fn Page::label(self : Page) -> String {
  match self {
    Workroom => "Workroom"
    BotDetail => "Bot"
    Inbox => "Inbox"
    Tasks => "Tasks"
    Manage => "Manage"
    Search => "Search"
    Settings => "Settings"
  }
}

///|
/// Localized navigation label. `label()` stays the stable English identifier
/// used by `MONEXUS_SCENE_PAGE` and tests; this is the one the shell paints.
pub fn Page::label_in(self : Page, lang : Lang) -> String {
  match self {
    Workroom => tr(lang, "Chats", "对话")
    BotDetail => tr(lang, "Bot", "Bot")
    Inbox => tr(lang, "Inbox", "收件箱")
    Tasks => tr(lang, "Tasks", "任务")
    Manage => tr(lang, "Manage", "管理")
    Search => tr(lang, "Search", "搜索")
    Settings => tr(lang, "Settings", "设置")
  }
}

///|
/// Parse both the new destinations and the pre-workroom labels. Keeping the
/// old spellings means existing scene/deep-link callers land on the closest
/// workroom destination instead of silently opening a removed page.
pub fn Page::from_label(value : String) -> Page {
  match value.to_lower() {
    "home" | "chat" | "chats" | "workroom" => Workroom
    "agents" | "bot" | "bots" | "botdetail" | "bot-detail" => BotDetail
    "machines" | "projects" | "manage" => Manage
    "inbox" => Inbox
    "tasks" => Tasks
    "search" => Search
    "settings" => Settings
    _ => Workroom
  }
}

///|
/// Secondary destination inside Manage. Projects and Machines are tabs of one
/// tools page, not peer top-level destinations.
#derive(Eq)
pub(all) enum ManageTab {
  ManageProjects
  ManageMachines
}

///|
pub fn ManageTab::label(self : ManageTab) -> String {
  match self {
    ManageProjects => "Projects"
    ManageMachines => "Machines"
  }
}

///|
pub fn ManageTab::label_in(self : ManageTab, lang : Lang) -> String {
  match self {
    ManageProjects => tr(lang, "Projects", "项目")
    ManageMachines => tr(lang, "Machines", "机器")
  }
}

///|
fn manage_tab_from_label(value : String) -> ManageTab {
  match value.to_lower() {
    "machines" => ManageMachines
    _ => ManageProjects
  }
}

///|
/// Tabs on the Bot identity/work-ledger page.
#derive(Eq)
pub(all) enum BotTab {
  BotHome
  BotChats
  BotAgents
  BotFiles
}

///|
pub fn BotTab::label_in(self : BotTab, lang : Lang) -> String {
  match self {
    BotHome => tr(lang, "Home", "主页")
    BotChats => tr(lang, "Chats", "聊天")
    BotAgents => tr(lang, "Agents", "Agents")
    BotFiles => tr(lang, "Files", "文件")
  }
}

///|
/// Presentation-only grouping for Bot work items. The underlying records stay
/// the existing Task projections; this only decides which ledger section a
/// status belongs to.
#derive(Eq)
pub(all) enum BotWorkGroup {
  BotWorkActive
  BotWorkWaiting
  BotWorkPlanned
  BotWorkClosed
}

///|
pub fn BotWorkGroup::label_in(self : BotWorkGroup, lang : Lang) -> String {
  match self {
    BotWorkActive => tr(lang, "In progress", "进行中")
    BotWorkWaiting => tr(lang, "Waiting", "等待中")
    BotWorkPlanned => tr(lang, "Planned", "已计划")
    BotWorkClosed => tr(lang, "Closed", "已关闭")
  }
}

///|
/// Typed presentation projection for `bot.list`/`chat.list`. The host RPCs
/// fill the underlying records; this view keeps only what the Chat shell paints
/// and never invents a history when the host has not projected one.
pub(all) struct ChatProjection {
  id : String
  bot_id : String
  title : String
  state : String
  updated_at : String
  project_id : String
  agent_session_id : String
  agent_name : String
  agent_state : String
  software_id : String
  participants : Array[String]
  pending_decision : String
  created_at : String
}

///|
/// Typed seam for Bot automations. No host projection exists yet, so the Bot
/// page paints a single honest empty row while keeping the shape ready.
pub(all) struct BotAutomation {
  id : String
  title : String
  cadence : String
  hint : String
}

///|
/// Small resolved identity used by the workroom header, sidebar and Bot page.
pub(all) struct BotIdentity {
  id : String
  name : String
  status : String
  summary : String
  is_fallback : Bool
}

///|
/// Small resolved Chat summary used by the workroom header and Chat rows.
pub(all) struct ChatIdentity {
  id : String
  bot_id : String
  title : String
  status : String
  updated_at : String
  agent_session_id : String
  is_fallback : Bool
  project_id : String
  agent_name : String
  agent_state : String
  software_id : String
}

///|
/// Form state for a real `chat.create` flow. Ids stay internal: every picker
/// shows a host projection name, never a raw bot_/cht_/asn_/ws_ value.
pub(all) struct ChatDraft {
  title : String
  bot_id : String
  project_id : String
  workspace_id : String
  agent_id : String
  bot_picker_open : Bool
  project_picker_open : Bool
  workspace_picker_open : Bool
  agent_picker_open : Bool
  message : String
  busy : Bool
}

///|
pub fn ChatDraft::new() -> ChatDraft {
  {
    title: "",
    bot_id: "",
    project_id: "",
    workspace_id: "",
    agent_id: "",
    bot_picker_open: false,
    project_picker_open: false,
    workspace_picker_open: false,
    agent_picker_open: false,
    message: "",
    busy: false,
  }
}

///|
#derive(Eq)
pub(all) enum ChatPicker {
  ChatPickerBot
  ChatPickerProject
  ChatPickerWorkspace
  ChatPickerAgent
}

///|
/// Form state for `bot.agent.create`. The runtime binding is described by
/// software and launch fields, not by asking the owner to paste an id.
pub(all) struct AgentDraft {
  name : String
  software : String
  launch_kind : String
  command : String
  args : String
  specialty : String
  software_picker_open : Bool
  message : String
  busy : Bool
}

///|
pub fn AgentDraft::new() -> AgentDraft {
  {
    name: "",
    software: "",
    launch_kind: @contracts.RUNTIME_LAUNCH_ACP,
    command: "",
    args: "",
    specialty: "",
    software_picker_open: false,
    message: "",
    busy: false,
  }
}

///|
/// Stable route targets used as navigation metadata. Raw ids live inside the
/// route path only; the painted UI uses names and titles.
pub(all) enum RouteTarget {
  RouteWorkroom
  RouteBot(String)
  RouteChat(String)
  RouteProjects(String)
}

///|
pub fn parse_route(value : String) -> RouteTarget {
  let path = value.trim().to_owned()
  if path == "" || path == "chat" || path == "chats" || path == "workroom" {
    return RouteWorkroom
  }
  if path.has_prefix("chat/") {
    let id = path[5:].to_owned()
    if id != "" {
      return RouteChat(id)
    }
  }
  if path.has_prefix("bot/") {
    let id = path[4:].to_owned()
    if id != "" {
      return RouteBot(id)
    }
  }
  if path.has_prefix("project/") {
    let id = path[8:].to_owned()
    if id != "" {
      return RouteProjects(id)
    }
  }
  match path.to_lower() {
    "project" | "projects" => RouteProjects("")
    "bot" | "bots" | "agents" => RouteBot("")
    _ => RouteWorkroom
  }
}

///|
pub fn route_path(target : RouteTarget) -> String {
  match target {
    RouteWorkroom => "chat"
    RouteBot(id) => if id == "" { "bot" } else { "bot/" + id }
    RouteChat(id) => "chat/" + id
    RouteProjects(id) => if id == "" { "project" } else { "project/" + id }
  }
}

///|
/// Filter sentinel for "Chats without a Project". It is UI-only navigation
/// metadata and never a host id.
pub const PROJECT_FILTER_NONE : String = "__no_project"

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
  projects : Array[@contracts.ProjectRecord]
  projects_loaded : Bool
  project_picker_open : Bool
  selected_project : String
  chat_bot_filter : String
  chat_bot_picker_open : Bool
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
  terminal_focus : Bool
  terminal_state : TerminalState
  terminal_eof : Bool
  terminal_error : String
  terminal_read_in_flight : Bool
  terminal_history : Array[String]
  terminal_scroll_epoch : Int32
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
    projects: [],
    projects_loaded: false,
    project_picker_open: false,
    selected_project: "",
    chat_bot_filter: "",
    chat_bot_picker_open: false,
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
    terminal_focus: false,
    terminal_state: TerminalClosed,
    terminal_eof: false,
    terminal_error: "",
    terminal_read_in_flight: false,
    terminal_history: [],
    terminal_scroll_epoch: 0,
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
  /// Prompt that actually started the active session in this window. It lets
  /// the workroom show one truthful user entry without parsing the raw ACP
  /// transcript into invented roles.
  launch_prompt : String
  /// Follow-ups submitted from this window. These are local UI facts, not a
  /// reconstructed transcript.
  sent_prompts : Array[String]
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
    launch_prompt: "",
    sent_prompts: [],
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
  /// Selected Manage tab. The page stays one destination while Projects and
  /// Machines switch as internal tabs.
  manage_tab : ManageTab
  /// Bot detail is a route inside the workroom, not an eighth primary entry.
  bot_tab : BotTab
  bots : Array[@contracts.BotRecord]
  chats : Array[ChatProjection]
  /// Rich host details backing `chats`; participants, current Agent and
  /// AgentSession state stay available without inventing fields.
  chat_details : Array[@contracts.ChatDetail]
  bots_loaded : Bool
  chats_loaded : Bool
  /// Selected Chat transcript, strictly from `chat.messages` and `chat.read`.
  chat_messages : Array[@contracts.ChatMessage]
  chat_messages_chat : String
  chat_messages_after : String
  chat_messages_loaded : Bool
  chat_read_cursor : Int64
  chat_live_text : String
  chat_session_state : String
  chat_pending_decision : String
  chat_workspace_id : String
  chat_poll_in_flight : Bool
  chat_messages_in_flight : Bool
  chat_read_in_flight : Bool
  /// Chat id currently being resolved through `chat.get`; prevents a route
  /// list refresh and a direct open from racing two detail requests.
  chat_get_chat : String
  chat_error : String
  chat_notice : String
  chat_draft : ChatDraft
  bot_agents : Array[@contracts.AgentRecord]
  bot_agents_bot : String
  bot_agents_loaded : Bool
  agent_draft : AgentDraft
  bot_project_filter : String
  bot_project_filter_open : Bool
  /// Deep-link target held until the matching projection arrives.
  route_target : RouteTarget
  route_note : String
  automations : Array[BotAutomation]
  selected_bot : String
  selected_chat : String
  composer_bot_picker_open : Bool
  composing_new_chat : Bool
  bot_work_open : String
  bot_show_all : Bool
  bot_agent_manage : Bool
  bot_comment : String
  bot_comment_note : String
  host : HostProjection
  machines : Array[@contracts.MachineRecord]
  machines_loaded : Bool
  machine_busy : String
  machine_message : String
  draft : MachineDraft
  project : ProjectState
  agent : AgentState
  /// Floating workspace overlay: a parallel note/Agent/terminal surface that
  /// never replaces the current route. Geometry and tab state stay in-model
  /// when the overlay is closed.
  float : FloatWorkspace
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
  let route_value = match @env.get_env_var("MONEXUS_ROUTE") {
    Some(value) if value.trim() != "" =>
      Some(value)
    _ =>
      match @env.get_env_var("MONEXUS_SCENE_PAGE") {
        Some(value) if value.contains("/") => Some(value)
        _ => None
      }
  }
  let route_target = match route_value {
    Some(value) => parse_route(value)
    None => RouteWorkroom
  }
  let page = match route_target {
    RouteWorkroom => Workroom
    RouteBot(_) => BotDetail
    RouteChat(_) => Workroom
    RouteProjects(_) => Manage
  }
  let page = match route_value {
    Some(_) => page
    _ =>
      match @env.get_env_var("MONEXUS_SCENE_PAGE") {
        Some(value) => Page::from_label(value)
        None => Workroom
      }
  }
  let manage_tab = match route_target {
    RouteProjects(_) => ManageProjects
    _ =>
      match @env.get_env_var("MONEXUS_SCENE_PAGE") {
        Some(value) =>
          if value.has_prefix("project") || value == "projects" {
            ManageProjects
          } else {
            manage_tab_from_label(value)
          }
        None => ManageProjects
      }
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
  let mut float = FloatWorkspace::new(language.language)
  match @env.get_env_var("MONEXUS_SCENE_FLOAT") {
    Some(value) => {
      let scene = value.to_lower()
      if scene != "" && scene != "off" && scene != "closed" {
        float = { ..float, open: true }
        if scene.contains("agent") {
          float = float_new_kind_tab(float, FloatAgent)
        }
        if scene.contains("terminal") {
          float = float_new_kind_tab(float, FloatTerminal)
        }
        if scene.contains("menu") {
          float = { ..float, menu_open: true }
        }
      }
    }
    None => ()
  }
  {
    page,
    manage_tab,
    bot_tab: BotHome,
    bots: [],
    chats: [],
    chat_details: [],
    bots_loaded: false,
    chats_loaded: false,
    chat_messages: [],
    chat_messages_chat: "",
    chat_messages_after: "",
    chat_messages_loaded: false,
    chat_read_cursor: 0L,
    chat_live_text: "",
    chat_session_state: "",
    chat_pending_decision: "",
    chat_workspace_id: "",
    chat_poll_in_flight: false,
    chat_messages_in_flight: false,
    chat_read_in_flight: false,
    chat_get_chat: "",
    chat_error: "",
    chat_notice: "",
    chat_draft: ChatDraft::new(),
    bot_agents: [],
    bot_agents_bot: "",
    bot_agents_loaded: false,
    agent_draft: AgentDraft::new(),
    bot_project_filter: "",
    bot_project_filter_open: false,
    route_target,
    route_note: "",
    automations: [],
    selected_bot: "",
    selected_chat: "",
    composer_bot_picker_open: false,
    composing_new_chat: false,
    bot_work_open: "",
    bot_show_all: false,
    bot_agent_manage: false,
    bot_comment: "",
    bot_comment_note: "",
    host,
    machines,
    machines_loaded: machines.length() > 0,
    machine_busy: "",
    machine_message: "",
    draft: MachineDraft::new(),
    project: ProjectState::new(),
    agent: AgentState::new(),
    float,
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
  SelectManageTab(ManageTab)
  /// Open a Bot. A known latest Chat wins; otherwise the Bot page opens.
  SelectBot(String)
  /// Open the Bot identity/work-ledger page directly. Used by Bot rows and the
  /// Bot identity in the Chat header so the Bot page is always reachable.
  OpenBotDetail(String)
  /// Select the Bot whose identity owns the next Chat from the composer.
  SelectComposerBot(String)
  ComposerBotPicker(Bool)
  /// Open a known Chat. The current Agent session remains the fallback when no
  /// Chat projection has been loaded yet.
  SelectChat(String)
  /// Start a fresh Chat flow without inventing a Chat record.
  NewChat
  /// Leave the new-Chat form without creating anything.
  CancelNewChat
  SelectBotTab(BotTab)
  ToggleBotWorkItem(String)
  OpenBotWorkItem(String)
  CloseBotWorkItem
  ToggleBotShowAll
  SetBotAgentManage(Bool)
  BotCommentDraft(String)
  BotCommentSave
  BotsLoaded(Array[@contracts.BotRecord])
  ChatsLoaded(Array[@contracts.ChatDetail])
  ChatOpened(@contracts.ChatDetail)
  ChatMessagesLoaded(
    String,
    Array[@contracts.ChatMessage],
    String,
    Bool,
  )
  ChatReadLoaded(String, @contracts.ChatReadResult)
  ChatSent(@contracts.ChatMessage, @contracts.AgentSession)
  ChatStopped(@contracts.AgentSession, Bool)
  ChatAgentSessionStarted(@contracts.AgentSession)
  ChatPoll
  ChatStartSession
  ChatError(String, String)
  ChatNotice(String)
  ChatCreateSubmit
  ChatDraftTitle(String)
  ChatDraftBot(String)
  ChatDraftProject(String)
  ChatDraftWorkspace(String)
  ChatDraftAgent(String)
  ChatDraftPicker(ChatPicker)
  BotAgentsLoaded(String, Array[@contracts.AgentRecord])
  AgentDraftName(String)
  AgentDraftSoftware(String)
  AgentDraftLaunch(String)
  AgentDraftCommand(String)
  AgentDraftArgs(String)
  AgentDraftSpecialty(String)
  AgentDraftSoftwarePicker(Bool)
  BotAgentCreateSubmit
  BotAgentMutated(@contracts.AgentRecord)
  SuspendBotAgent(String)
  RetireBotAgent(String)
  BotProjectFilter(String)
  BotProjectFilterPicker(Bool)
  SelectProject(String)
  ProjectCatalogLoaded(Array[@contracts.ProjectRecord])
  ProjectCatalogPicker(Bool)
  ProjectChatBotFilter(String)
  ProjectChatBotPicker(Bool)
  RouteArrived(RouteTarget)
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
  ProjectTerminalOpened(String, String, Int64, Bool)
  ProjectTerminalOutput(String, Int64, String, Bool)
  ProjectTerminalFailed(String, String)
  ProjectTerminalPoll
  ProjectTerminalFocus
  ProjectTerminalBack
  ProjectTerminalReconnect
  ProjectTerminalClear
  ProjectTerminalClose
  ProjectTerminalStop
  ProjectTerminalHistory(String)
  ProjectTerminalTranscriptEdited(String)
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
  /// Composer send: starts the fallback Agent session when there is no active
  /// Chat yet, otherwise submits a follow-up to the current session.
  ComposerSend
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
  // Floating workspace overlay.
  ToggleFloatWorkspace
  CloseFloatWorkspace
  FloatSelectTab(String)
  FloatCloseTab(String)
  FloatNewNote
  FloatNewAgent
  FloatNewTerminal
  FloatMenu(Bool)
  FloatNoteTitleDraft(String)
  FloatNoteContentDraft(String)
  FloatNoteStored(String, Int, Bool, String)
  FloatWorkspaceRestored(FloatWorkspaceRestore)
  FloatHeaderDrag(@core.DragGesturePhase, Double, Double)
  FloatResizeDrag(@core.DragGesturePhase, Double, Double)
  FloatOpenTerminal
  FloatTerminalReconnect
  FloatNoop
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
  ProjectTerminalWrite(String, String)
  ProjectTerminalRead(String, Int64)
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
  // Bots / Chats: real P0.3 RPC projections.
  BotList
  ChatList(String, String)
  ChatGet(String)
  ChatMessages(String, String, Int32)
  ChatRead(String, Int64)
  ChatCreate(
    String,
    String,
    String,
    String,
    String,
    String,
  )
  ChatAgentSessionStart(String, String, String)
  ChatSend(String, String)
  ChatStop(String, String)
  BotAgentList(String)
  BotAgentCreate(
    String,
    String,
    String,
    String,
    String,
    Array[String],
    String,
  )
  BotAgentSuspend(String, String)
  BotAgentRetire(String, String)
  ProjectCatalog
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
/// Chat sessions need an open workspace before `chat.agent_session.start`.
/// Prefer the selected Project workspace, then the most recent open workspace,
/// then the Agent page selection; never manufacture an id.
fn chat_default_workspace_id(model : Model) -> String {
  let selected = default_workspace_id(model, model.project.workspaces)
  if selected != "" {
    selected
  } else {
    model.agent.workspace_id
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
  let chat_workspace = if model.composing_new_chat &&
    model.chat_draft.workspace_id == "" {
    default
  } else {
    model.chat_draft.workspace_id
  }
  {
    ..model,
    agent: { ..model.agent, workspace_id: agent_workspace },
    task: { ..model.task, workspace_id: task_workspace },
    chat_draft: { ..model.chat_draft, workspace_id: chat_workspace },
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
fn bot_by_id(
  records : Array[@contracts.BotRecord],
  id : String,
) -> @contracts.BotRecord? {
  for record in records {
    if record.id == id {
      return Some(record)
    }
  }
  None
}

///|
fn agent_record_by_id(
  records : Array[@contracts.AgentRecord],
  id : String,
) -> @contracts.AgentRecord? {
  for record in records {
    if record.id == id {
      return Some(record)
    }
  }
  None
}

///|
fn chat_detail_by_id(
  records : Array[@contracts.ChatDetail],
  id : String,
) -> @contracts.ChatDetail? {
  for detail in records {
    if detail.chat.id == id {
      return Some(detail)
    }
  }
  None
}

///|
fn chat_projection_from_detail(detail : @contracts.ChatDetail) -> ChatProjection {
  let chat = detail.chat
  let agent_name = match detail.agent {
    Some(agent) => agent.name
    None => ""
  }
  let software_id = match detail.agent {
    Some(agent) => agent.runtime_binding.software_id
    None => ""
  }
  let session_id = match detail.active_agent_session {
    Some(session) => session.id
    None => ""
  }
  let session_state = match detail.active_agent_session {
    Some(session) => session.state
    None => ""
  }
  let participants : Array[String] = []
  for participant in detail.participants {
    if participant.state == @contracts.PARTICIPANT_STATE_ACTIVE {
      participants.push(participant.bot_id)
    }
  }
  {
    id: chat.id,
    bot_id: match participants {
      [bot_id, ..] => bot_id
      [] => ""
    },
    title: chat.title,
    state: chat.state,
    updated_at: chat.updated_at,
    project_id: chat.project_id,
    agent_session_id: session_id,
    agent_name,
    agent_state: session_state,
    software_id,
    participants,
    pending_decision: "",
    created_at: chat.created_at,
  }
}

///|
fn chats_with_detail(
  records : Array[ChatProjection],
  detail : @contracts.ChatDetail,
) -> Array[ChatProjection] {
  let next = chat_projection_from_detail(detail)
  let out : Array[ChatProjection] = []
  let mut replaced = false
  for record in records {
    if record.id == next.id {
      out.push({
        ..next,
        pending_decision: record.pending_decision,
      })
      replaced = true
    } else {
      out.push(record)
    }
  }
  if !replaced {
    out.push(next)
  }
  out
}

///|
fn details_with(
  records : Array[@contracts.ChatDetail],
  detail : @contracts.ChatDetail,
) -> Array[@contracts.ChatDetail] {
  let out : Array[@contracts.ChatDetail] = []
  let mut replaced = false
  for record in records {
    if record.chat.id == detail.chat.id {
      out.push(detail)
      replaced = true
    } else {
      out.push(record)
    }
  }
  if !replaced {
    out.push(detail)
  }
  out
}

///|
fn detail_session_id(detail : @contracts.ChatDetail) -> String {
  match detail.active_agent_session {
    Some(session) => session.id
    None => ""
  }
}

///|
fn chat_for_session(model : Model, session_id : String) -> ChatProjection? {
  if session_id == "" {
    return None
  }
  for chat in model.chats {
    if chat.agent_session_id == session_id {
      return Some(chat)
    }
  }
  for detail in model.chat_details {
    match detail.active_agent_session {
      Some(session) =>
        if session.id == session_id {
          return Some(chat_projection_from_detail(detail))
        }
      None => ()
    }
  }
  None
}

///|
fn chat_agent_id_for(model : Model, chat_id : String) -> String {
  match chat_detail_by_id(model.chat_details, chat_id) {
    Some(detail) =>
      match detail.agent {
        Some(agent) => agent.id
        None => ""
      }
    None => ""
  }
}

///|
fn active_session_of_detail(
  detail : @contracts.ChatDetail,
) -> @contracts.AgentSession? {
  detail.active_agent_session
}

///|
fn chat_project_label(model : Model, project_id : String) -> String {
  if project_id == "" {
    return tr(model.lang, "No project", "无项目")
  }
  for record in model.project.projects {
    if record.id == project_id {
      return if record.name == "" {
        tr(model.lang, "Untitled project", "未命名项目")
      } else {
        record.name
      }
    }
  }
  tr(model.lang, "Unmapped project", "未映射项目")
}

///|
fn project_name(record : @contracts.ProjectRecord) -> String {
  if record.name.trim() == "" {
    "Untitled project"
  } else {
    record.name
  }
}

///|
fn bot_recent_activity(model : Model, bot : @contracts.BotRecord) -> String {
  match latest_chat_for_bot(model.chats, bot.id) {
    Some(chat) =>
      if chat.updated_at != "" {
        compact_time(chat.updated_at)
      } else if chat.created_at != "" {
        compact_time(chat.created_at)
      } else {
        ""
      }
    None =>
      if bot.updated_at != "" {
        compact_time(bot.updated_at)
      } else {
        compact_time(bot.created_at)
      }
  }
}

///|
fn bots_in_project(model : Model, project_id : String) -> Array[@contracts.BotRecord] {
  if project_id == "" {
    return model.bots.copy()
  }
  let none_filter = project_id == PROJECT_FILTER_NONE
  let out : Array[@contracts.BotRecord] = []
  for bot in model.bots {
    let mut member = false
    for chat in model.chats {
      let in_scope = if none_filter {
        chat.project_id == ""
      } else {
        chat.project_id == project_id
      }
      if in_scope && chat.participants.contains(bot.id) {
        member = true
      }
    }
    if member {
      out.push(bot)
    }
  }
  out
}

///|
fn chats_in_project(model : Model, project_id : String) -> Array[ChatProjection] {
  if project_id == "" {
    return model.chats.copy()
  }
  let out : Array[ChatProjection] = []
  for chat in model.chats {
    if chat.project_id == project_id {
      out.push(chat)
    }
  }
  out
}

///|
fn chat_matches_project_filter(
  chat : ChatProjection,
  filter_id : String,
) -> Bool {
  if filter_id == "" {
    true
  } else if filter_id == PROJECT_FILTER_NONE {
    chat.project_id == ""
  } else {
    chat.project_id == filter_id
  }
}

///|
fn project_filter_label(model : Model, filter_id : String) -> String {
  if filter_id == "" {
    tr(model.lang, "All projects", "全部项目")
  } else if filter_id == PROJECT_FILTER_NONE {
    tr(model.lang, "No project", "无项目")
  } else {
    match project_by_id(model.project.projects, filter_id) {
      Some(record) => project_name(record)
      None => tr(model.lang, "Unmapped project", "未映射项目")
    }
  }
}

///|
fn project_chats_filtered(
  model : Model,
  project_id : String,
  bot_id : String,
) -> Array[ChatProjection] {
  let out : Array[ChatProjection] = []
  for chat in chats_in_project(model, project_id) {
    if bot_id == "" ||
      chat.bot_id == bot_id ||
      chat.participants.contains(bot_id) {
      out.push(chat)
    }
  }
  out
}

///|
fn chats_for_bot(
  model : Model,
  bot_id : String,
) -> Array[ChatProjection] {
  let out : Array[ChatProjection] = []
  for chat in model.chats {
    if bot_id == "" ||
      chat.bot_id == bot_id ||
      chat.participants.contains(bot_id) {
      out.push(chat)
    }
  }
  out
}

///|
fn bot_chats_filtered(
  model : Model,
  bot_id : String,
  project_filter : String,
) -> Array[ChatProjection] {
  let out : Array[ChatProjection] = []
  for chat in chats_for_bot(model, bot_id) {
    if chat_matches_project_filter(chat, project_filter) {
      out.push(chat)
    }
  }
  out
}

///|
fn merge_chat_messages(
  existing : Array[@contracts.ChatMessage],
  incoming : Array[@contracts.ChatMessage],
) -> Array[@contracts.ChatMessage] {
  let out : Array[@contracts.ChatMessage] = existing.copy()
  for message in incoming {
    let mut present = false
    for current in out {
      if current.id == message.id {
        present = true
        break
      }
    }
    if !present {
      out.push(message)
    }
  }
  out
}

///|
fn last_chat_message_id(records : Array[@contracts.ChatMessage]) -> String {
  if records.is_empty() {
    ""
  } else {
    records[records.length() - 1].id
  }
}

///|
fn chat_session_active(state : String) -> Bool {
  state == @contracts.AGENT_SESSION_STATE_STARTING ||
  state == @contracts.AGENT_SESSION_STATE_ACTIVE ||
  state == @contracts.AGENT_SESSION_STATE_WAITING ||
  state == @contracts.AGENT_SESSION_STATE_ENDING
}

///|
fn bot_agents_loaded_for(model : Model, bot_id : String) -> Bool {
  model.bot_agents_loaded && model.bot_agents_bot == bot_id
}

///|
fn selectable_agent_id(records : Array[@contracts.AgentRecord]) -> String {
  for record in records {
    if record.state != @contracts.AGENT_LIFECYCLE_SUSPENDED &&
      record.state != @contracts.AGENT_LIFECYCLE_RETIRED {
      return record.id
    }
  }
  ""
}

///|
fn agent_for_bot(
  records : Array[@contracts.AgentRecord],
  agent_id : String,
) -> @contracts.AgentRecord? {
  for record in records {
    if record.id == agent_id &&
      record.state != @contracts.AGENT_LIFECYCLE_SUSPENDED &&
      record.state != @contracts.AGENT_LIFECYCLE_RETIRED {
      return Some(record)
    }
  }
  None
}

///|
fn split_command_args(value : String) -> Array[String] {
  let out : Array[String] = []
  for part in value.split(" ") {
    let trimmed = part.trim().to_owned()
    if trimmed != "" {
      out.push(trimmed)
    }
  }
  out
}

///|
fn project_by_id(
  records : Array[@contracts.ProjectRecord],
  id : String,
) -> @contracts.ProjectRecord? {
  for record in records {
    if record.id == id {
      return Some(record)
    }
  }
  None
}

///|
pub fn model_route(model : Model) -> String {
  match model.page {
    BotDetail => {
      let route_id = match model.route_target {
        RouteBot(id) => id
        _ => ""
      }
      route_path(RouteBot(if model.selected_bot != "" {
        model.selected_bot
      } else {
        route_id
      }))
    }
    Workroom =>
      if model.selected_chat != "" && !model.composing_new_chat {
        route_path(RouteChat(model.selected_chat))
      } else {
        match model.route_target {
          RouteChat(id) if id != "" && !model.composing_new_chat =>
            route_path(RouteChat(id))
          _ => route_path(RouteWorkroom)
        }
      }
    Manage => {
      let route_id = match model.route_target {
        RouteProjects(id) => id
        _ => ""
      }
      route_path(RouteProjects(if model.project.selected_project != "" {
        model.project.selected_project
      } else {
        route_id
      }))
    }
    _ => model.page.label().to_lower()
  }
}

///|
fn chat_by_id(
  records : Array[ChatProjection],
  id : String,
) -> ChatProjection? {
  for record in records {
    if record.id == id {
      return Some(record)
    }
  }
  None
}

///|
fn latest_chat_for_bot(
  records : Array[ChatProjection],
  bot_id : String,
) -> ChatProjection? {
  let mut best : ChatProjection? = None
  for record in records {
    if record.bot_id != bot_id {
      continue
    }
    let replace = match best {
      None => true
      Some(current) =>
        record.updated_at > current.updated_at ||
        (record.updated_at == current.updated_at && record.id < current.id)
    }
    if replace {
      best = Some(record)
    }
  }
  best
}

///|
fn bot_name(record : @contracts.BotRecord) -> String {
  if record.name.trim() == "" {
    "Unnamed bot"
  } else {
    record.name
  }
}

///|
fn bot_identity_for(model : Model, record : @contracts.BotRecord) -> BotIdentity {
  let summary =
    tr(model.lang, "Bot identity", "Bot 身份") +
    (if record.state == "" {
      ""
    } else {
      " · " + record.state
    }) +
    (if record.home == "" {
      ""
    } else {
      " · " + record.home
    })
  {
    id: record.id,
    name: bot_name(record),
    status: record.state,
    summary,
    is_fallback: false,
  }
}

///|
fn session_bot_identity(
  model : Model,
  record : @contracts.AgentSessionRecord,
) -> BotIdentity {
  let name = if record.agent_name.trim() == "" {
    tr(model.lang, "Default agent", "默认智能体")
  } else {
    record.agent_name
  }
  let summary =
    (if record.workspace_id == "" {
      tr(model.lang, "Current agent session", "当前智能体会话")
    } else {
      workspace_context_name(model, record.workspace_id)
    }) +
    (if record.mode == "" {
      ""
    } else {
      " · " + record.mode
    })
  {
    id: record.agent_id,
    name,
    status: model.agent.state_text,
    summary,
    is_fallback: true,
  }
}

///|
fn chat_identity_for(
  model : Model,
  record : ChatProjection,
) -> ChatIdentity {
  {
    id: record.id,
    bot_id: record.bot_id,
    title: if record.title.trim() == "" {
      tr(model.lang, "Untitled chat", "未命名对话")
    } else {
      record.title
    },
    status: record.state,
    updated_at: record.updated_at,
    agent_session_id: record.agent_session_id,
    is_fallback: false,
    project_id: record.project_id,
    agent_name: record.agent_name,
    agent_state: record.agent_state,
    software_id: record.software_id,
  }
}

///|
/// Resolve the Chat the workroom is showing. A selected Chat projection wins;
/// with none loaded, the current Agent session is the one honest active Chat.
pub fn active_chat_identity(model : Model) -> ChatIdentity? {
  if model.composing_new_chat {
    return None
  }
  if model.selected_chat != "" {
    match chat_by_id(model.chats, model.selected_chat) {
      Some(record) => return Some(chat_identity_for(model, record))
      None => ()
    }
  }
  match model.agent.session {
    Some(record) =>
      Some({
        id: record.id,
        bot_id: if model.selected_bot == "" {
          record.agent_id
        } else {
          model.selected_bot
        },
        title: tr(model.lang, "Current session", "当前会话"),
        status: if model.agent.state_text == "" {
          record.state
        } else {
          model.agent.state_text
        },
        updated_at: session_recency(record),
        agent_session_id: record.id,
        is_fallback: true,
        project_id: "",
        agent_name: record.agent_name,
        agent_state: record.state,
        software_id: "",
      })
    None => None
  }
}

///|
/// Resolve the active Bot identity. Loaded Bot projections win; before P0.3
/// data exists, the current Agent session supplies one truthful fallback row.
pub fn active_bot_identity(model : Model) -> BotIdentity {
  if model.selected_bot != "" {
    match bot_by_id(model.bots, model.selected_bot) {
      Some(record) => return bot_identity_for(model, record)
      None => ()
    }
  }
  match active_chat_identity(model) {
    Some(chat) =>
      if chat.bot_id != "" {
        match bot_by_id(model.bots, chat.bot_id) {
          Some(record) => return bot_identity_for(model, record)
          None => ()
        }
      }
    None => ()
  }
  match model.bots {
    [record, ..] => return bot_identity_for(model, record)
    [] => ()
  }
  match model.agent.session {
    Some(record) => session_bot_identity(model, record)
    None =>
      {
        id: "",
        name: tr(model.lang, "MoNexus", "MoNexus"),
        status: tr(model.lang, "waiting", "等待中"),
        summary: tr(
          model.lang,
          "No Bot projection loaded",
          "尚未加载 Bot 投影",
        ),
        is_fallback: true,
      }
  }
}

///|
pub fn workspace_context_name(model : Model, workspace_id : String) -> String {
  if workspace_id == "" {
    return ""
  }
  match workspace_by_id(model.project.workspaces, workspace_id) {
    Some(record) => workspace_display_name(record)
    None => tr(model.lang, "Workspace not open", "工作区未打开")
  }
}

///|
pub fn chat_uses_current_session(model : Model, chat : ChatIdentity) -> Bool {
  match model.agent.session {
    Some(record) =>
      chat.is_fallback ||
      chat.agent_session_id == record.id ||
      chat.id == record.id
    None => false
  }
}

///|
fn compact_time(value : String) -> String {
  if value == "" {
    return ""
  }
  let spaced = value.replace(old="T", new=" ")
  let stamp = if spaced.has_suffix("Z") {
    spaced[:spaced.length() - 1].to_owned()
  } else {
    spaced
  }
  if stamp.length() >= 16 {
    stamp[:16].to_owned()
  } else {
    stamp
  }
}

///|
fn task_group_of(status : String) -> BotWorkGroup {
  match status {
    @contracts.TASK_STATUS_RUNNING => BotWorkActive
    @contracts.TASK_STATUS_WAITING_APPROVAL |
    @contracts.TASK_STATUS_WAITING_OWNER |
    @contracts.TASK_STATUS_BLOCKED =>
      BotWorkWaiting
    @contracts.TASK_STATUS_DRAFT |
    @contracts.TASK_STATUS_PLANNED |
    @contracts.TASK_STATUS_READY =>
      BotWorkPlanned
    _ => BotWorkClosed
  }
}

///|
fn short_metadata_id(value : String) -> String {
  if value.length() <= 10 {
    value
  } else {
    "…" + value[value.length() - 8:].to_owned()
  }
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
        selected_bot: if page == BotDetail && model.selected_bot == "" {
          active_bot_identity(model).id
        } else {
          model.selected_bot
        },
        route_target: match page {
          Workroom =>
            if model.selected_chat != "" && !model.composing_new_chat {
              RouteChat(model.selected_chat)
            } else {
              RouteWorkroom
            }
          BotDetail =>
            RouteBot(if model.selected_bot == "" {
              active_bot_identity(model).id
            } else {
              model.selected_bot
            })
          Manage => RouteProjects(model.project.selected_project)
          _ => RouteWorkroom
        },
        hover_row: "",
        scroll_epoch: model.scroll_epoch + 1,
      },
      match page {
        Workroom => [
          AgentList,
          BotList,
          ChatList("", ""),
          ProjectList,
          ProjectCatalog,
          RefreshMachines,
          TaskRefresh(model.task.event_seq),
          DecisionList(""),
        ]
        BotDetail => [
          AgentList,
          BotList,
          ChatList("", ""),
          ProjectList,
          ProjectCatalog,
          RefreshMachines,
          TaskRefresh(model.task.event_seq),
        ]
        Inbox => [DecisionList("")]
        Tasks => [TaskRefresh(model.task.event_seq), ProjectList, RefreshMachines]
        Manage =>
          match model.manage_tab {
            ManageProjects => [
              ProjectList,
              ProjectCatalog,
              BotList,
              ChatList("", ""),
              RefreshMachines,
            ]
            ManageMachines => [RefreshMachines]
          }
        _ => none
      },
    )
    SelectManageTab(tab) => (
      {
        ..model,
        page: Manage,
        manage_tab: tab,
        route_target: match tab {
          ManageProjects => RouteProjects(model.project.selected_project)
          ManageMachines => RouteWorkroom
        },
        hover_row: "",
        scroll_epoch: model.scroll_epoch + 1,
      },
      match tab {
        ManageProjects => [
          ProjectList,
          ProjectCatalog,
          BotList,
          ChatList("", ""),
          RefreshMachines,
        ]
        ManageMachines => [RefreshMachines]
      },
    )
    SelectBot(bot_id) => {
      let latest = latest_chat_for_bot(model.chats, bot_id)
      match latest {
        Some(chat) =>
          update_full(
            {
              ..model,
              selected_bot: bot_id,
              hover_row: "",
            },
            SelectChat(chat.id),
          )
        None =>
          (
            {
              ..model,
              page: BotDetail,
              bot_tab: BotHome,
              selected_bot: bot_id,
              composing_new_chat: false,
              route_target: RouteBot(bot_id),
              hover_row: "",
              scroll_epoch: model.scroll_epoch + 1,
            },
            [
              AgentList,
              BotList,
              ChatList("", ""),
              BotAgentList(bot_id),
              ProjectList,
              ProjectCatalog,
              RefreshMachines,
              TaskRefresh(model.task.event_seq),
            ],
          )
      }
    }
    OpenBotDetail(bot_id) => (
      {
        ..model,
        page: BotDetail,
        bot_tab: BotHome,
        selected_bot: if bot_id == "" {
          active_bot_identity(model).id
        } else {
          bot_id
        },
        bot_work_open: "",
        bot_agent_manage: false,
        bot_comment_note: "",
        composing_new_chat: false,
        route_target: RouteBot(if bot_id == "" {
          active_bot_identity(model).id
        } else {
          bot_id
        }),
        hover_row: "",
        scroll_epoch: model.scroll_epoch + 1,
      },
      [
        AgentList,
        BotList,
        ChatList("", ""),
        BotAgentList(if bot_id == "" {
          active_bot_identity(model).id
        } else {
          bot_id
        }),
        ProjectList,
        ProjectCatalog,
        RefreshMachines,
        TaskRefresh(model.task.event_seq),
      ],
    )
    SelectComposerBot(bot_id) => (
      {
        ..model,
        selected_bot: bot_id,
        composer_bot_picker_open: false,
      },
      none,
    )
    ComposerBotPicker(open) => (
      { ..model, composer_bot_picker_open: open },
      none,
    )
    SelectChat(chat_id) =>
      match chat_by_id(model.chats, chat_id) {
        Some(chat) => {
          let detail = chat_detail_by_id(model.chat_details, chat.id)
          let session = match detail {
            Some(value) => value.active_agent_session
            None => None
          }
          let session_id = match session {
            Some(record) => record.id
            None => chat.agent_session_id
          }
          let workspace_id = match session {
            Some(record) =>
              if record.workspace_id == "" {
                chat_default_workspace_id(model)
              } else {
                record.workspace_id
              }
            None => chat_default_workspace_id(model)
          }
          let agent = {
            ..model.agent,
            workspace_id,
            transcript: "",
            cursor: 0L,
            pending_decision: "",
            state_text: if session_id == "" {
              chat.state
            } else {
              chat.agent_state
            },
            stop_reason: "",
          }
          (
            {
              ..model,
              page: Workroom,
              selected_bot: chat.bot_id,
              selected_chat: chat.id,
              composing_new_chat: false,
              agent,
              chat_messages: [],
              chat_messages_chat: chat.id,
              chat_messages_after: "",
              chat_messages_loaded: false,
              chat_read_cursor: 0L,
              chat_live_text: "",
              chat_session_state: if session_id == "" {
                chat.state
              } else {
                chat.agent_state
              },
              chat_pending_decision: chat.pending_decision,
              chat_workspace_id: workspace_id,
              chat_poll_in_flight: false,
              chat_messages_in_flight: false,
              chat_read_in_flight: false,
              chat_get_chat: chat.id,
              chat_error: "",
              chat_notice: "",
              route_target: RouteChat(chat.id),
              route_note: "",
              hover_row: "",
              scroll_epoch: model.scroll_epoch + 1,
            },
            // `ChatOpened` owns the one initial messages/read load after
            // `chat.get` returns the authoritative participants and session.
            [ChatGet(chat.id)],
          )
        }
        None => (
          {
            ..model,
            chat_error: tr(
              model.lang,
              "Chat is not in the loaded projection",
              "对话不在已加载的投影中",
            ),
          },
          none,
        )
      }
    NewChat => {
      let project_id = if model.page == Manage {
        model.project.selected_project
      } else if model.bot_project_filter == PROJECT_FILTER_NONE {
        ""
      } else {
        model.bot_project_filter
      }
      let member_bots = if project_id == "" {
        model.bots.copy()
      } else {
        bots_in_project(model, project_id)
      }
      let preferred = if model.selected_bot != "" {
        model.selected_bot
      } else {
        active_bot_identity(model).id
      }
      let bot_id = if project_id == "" {
        preferred
      } else if bot_by_id(member_bots, preferred) is Some(_) {
        preferred
      } else {
        match member_bots {
          [record, ..] => record.id
          [] => ""
        }
      }
      let workspace_id = match model.project.workspace {
        Some(record) => record.id
        None =>
          match model.project.workspaces {
            [record, ..] => record.id
            [] => model.agent.workspace_id
          }
      }
      let agent_id = match model.bot_agents {
        [record, ..] => if record.bot_id == bot_id { record.id } else { "" }
        _ => ""
      }
      let draft = {
        ..model.chat_draft,
        title: "",
        bot_id,
        project_id,
        workspace_id,
        agent_id,
        bot_picker_open: false,
        project_picker_open: false,
        workspace_picker_open: false,
        agent_picker_open: false,
        message: if project_id != "" && member_bots.is_empty() {
          tr(
            model.lang,
            "No Bot has active membership evidence in this Project. The host exposes no project.membership.list RPC, so this window will not guess; choose a Bot view Chat with Project membership first.",
            "没有 Bot 在此项目中有有效成员证据。主机未暴露 project.membership.list RPC，因此此窗口不会猜测；请先选择在项目中有成员资格的 Bot 对话。",
          )
        } else {
          ""
        },
        busy: false,
      }
      (
        {
          ..model,
          page: Workroom,
          selected_chat: "",
          selected_bot: bot_id,
          composer_bot_picker_open: false,
          composing_new_chat: true,
          chat_draft: draft,
          chat_messages: [],
          chat_messages_chat: "",
          chat_messages_after: "",
          chat_messages_loaded: false,
          chat_read_cursor: 0L,
          chat_live_text: "",
          chat_session_state: "",
          chat_pending_decision: "",
          chat_error: "",
          chat_notice: "",
          chat_poll_in_flight: false,
          chat_messages_in_flight: false,
          chat_read_in_flight: false,
          chat_get_chat: "",
          bot_comment_note: "",
          route_target: RouteWorkroom,
          route_note: "",
          scroll_epoch: model.scroll_epoch + 1,
        },
        {
          let commands : Array[MachineCommand] = []
          if !model.bots_loaded {
            commands.push(BotList)
          }
          if !model.chats_loaded {
            commands.push(ChatList("", ""))
          }
          if !model.project.projects_loaded {
            commands.push(ProjectCatalog)
          }
          if !model.project.workspaces_loaded {
            commands.push(ProjectList)
          }
          if bot_id != "" {
            commands.push(BotAgentList(bot_id))
          }
          commands
        },
      )
    }
    CancelNewChat => (
      {
        ..model,
        composing_new_chat: false,
        page: Workroom,
        chat_draft: { ..model.chat_draft, busy: false, message: "" },
        chat_get_chat: "",
        chat_messages_in_flight: false,
        chat_read_in_flight: false,
        chat_poll_in_flight: false,
        route_target: if model.selected_chat == "" {
          RouteWorkroom
        } else {
          RouteChat(model.selected_chat)
        },
        scroll_epoch: model.scroll_epoch + 1,
      },
      none,
    )
    SelectBotTab(tab) => (
      {
        ..model,
        page: BotDetail,
        bot_tab: tab,
        selected_bot: if model.selected_bot == "" {
          active_bot_identity(model).id
        } else {
          model.selected_bot
        },
        bot_agent_manage: false,
        route_target: RouteBot(if model.selected_bot == "" {
          active_bot_identity(model).id
        } else {
          model.selected_bot
        }),
        scroll_epoch: model.scroll_epoch + 1,
      },
      match tab {
        BotAgents => [BotAgentList(model.selected_bot)]
        BotChats => [ChatList("", "")]
        _ => none
      },
    )
    ToggleBotWorkItem(task_id) => (
      {
        ..model,
        bot_work_open: if model.bot_work_open == task_id {
          ""
        } else {
          task_id
        },
      },
      none,
    )
    OpenBotWorkItem(task_id) => (
      { ..model, bot_work_open: task_id },
      none,
    )
    CloseBotWorkItem => ({ ..model, bot_work_open: "" }, none)
    ToggleBotShowAll => (
      { ..model, bot_show_all: !model.bot_show_all },
      none,
    )
    SetBotAgentManage(open) => (
      { ..model, bot_agent_manage: open },
      none,
    )
    BotCommentDraft(value) => (
      { ..model, bot_comment: value, bot_comment_note: "" },
      none,
    )
    BotCommentSave =>
      if model.bot_comment.trim() == "" {
        (
          {
            ..model,
            bot_comment_note: tr(
              model.lang,
              "Write a comment first.",
              "请先输入评论。",
            ),
          },
          none,
        )
      } else if model.bot_comment.to_array().length() > 50 {
        (
          {
            ..model,
            bot_comment_note: tr(
              model.lang,
              "Comments are limited to 50 characters.",
              "评论最多 50 个字符。",
            ),
          },
          none,
        )
      } else {
        (
          {
            ..model,
            bot_comment: "",
            bot_comment_note: tr(
              model.lang,
              "Comment kept in this window only; host comment persistence is not available yet.",
              "评论仅保留在当前窗口；主机评论持久化尚未提供。",
            ),
          },
          none,
        )
      }
    BotsLoaded(records) => {
      let bots : Array[@contracts.BotRecord] = []
      for record in records {
        bots.push(record)
      }
      let route_bot = match model.route_target {
        RouteBot(id) => id
        _ => ""
      }
      let mut selected_bot = model.selected_bot
      if route_bot != "" && bot_by_id(bots, route_bot) is Some(_) {
        selected_bot = route_bot
      } else if selected_bot == "" || bot_by_id(bots, selected_bot) is None {
        selected_bot = if bots.is_empty() { "" } else { bots[0].id }
      }
      let mut page = model.page
      let mut bot_tab = model.bot_tab
      let mut route_target = model.route_target
      let mut route_note = model.route_note
      match model.route_target {
        RouteBot(id) =>
          if bot_by_id(bots, id) is Some(_) {
            page = BotDetail
            bot_tab = BotHome
            route_target = RouteBot(id)
            route_note = ""
          } else if id != "" {
            route_note = tr(
              model.lang,
              "Bot route was not found in the loaded projection.",
              "已加载的投影中没有该 Bot 路由。",
            )
          }
        _ => ()
      }
      (
        {
          ..model,
          bots,
          bots_loaded: true,
          selected_bot,
          chat_draft: if model.composing_new_chat &&
            model.chat_draft.bot_id == "" &&
            selected_bot != "" {
            { ..model.chat_draft, bot_id: selected_bot }
          } else {
            model.chat_draft
          },
          page,
          bot_tab,
          route_target,
          route_note,
        },
        if selected_bot == "" { none } else { [BotAgentList(selected_bot)] },
      )
    }
    ChatsLoaded(records) => {
      let chats : Array[ChatProjection] = []
      let details : Array[@contracts.ChatDetail] = []
      for record in records {
        chats.push(chat_projection_from_detail(record))
        details.push(record)
      }
      let route_chat = match model.route_target {
        RouteChat(id) => id
        _ => ""
      }
      let mut route_target = model.route_target
      let mut route_note = model.route_note
      let mut page = model.page
      let mut chat_get_chat = model.chat_get_chat
      let mut selected_chat = ""
      if route_chat != "" && chat_by_id(chats, route_chat) is Some(_) {
        selected_chat = route_chat
      } else if model.selected_chat != "" &&
        chat_by_id(chats, model.selected_chat) is Some(_) {
        selected_chat = model.selected_chat
      }
      if selected_chat == "" &&
        page == Workroom &&
        !model.composing_new_chat &&
        !chats.is_empty() {
        let mut best = chats[0]
        for record in chats {
          if record.updated_at > best.updated_at ||
            (record.updated_at == best.updated_at && record.id < best.id) {
            best = record
          }
        }
        selected_chat = best.id
      }
      let mut open_chat = ""
      match model.route_target {
        RouteChat(id) =>
          if chat_by_id(chats, id) is Some(_) {
            page = Workroom
            route_target = RouteChat(id)
            route_note = ""
            selected_chat = id
            open_chat = id
          } else if id != "" {
            route_note = tr(
              model.lang,
              "Chat route was not found in the loaded projection.",
              "已加载的投影中没有该对话路由。",
            )
            open_chat = id
          }
        _ => ()
      }
      if open_chat == "" && page == Workroom && model.selected_chat == "" &&
        selected_chat != "" && !model.composing_new_chat {
        open_chat = selected_chat
      }
      let commands : Array[MachineCommand] = []
      if open_chat != "" && chat_get_chat != open_chat {
        chat_get_chat = open_chat
        commands.push(ChatGet(open_chat))
      }
      (
        {
          ..model,
          chats,
          chat_details: details,
          chats_loaded: true,
          selected_chat,
          page,
          route_target,
          route_note,
          chat_get_chat,
        },
        commands,
      )
    }
    ChatOpened(detail) =>
      if model.page != Workroom ||
        (model.composing_new_chat && !model.chat_draft.busy) ||
        (model.chat_get_chat != "" &&
          model.chat_get_chat != detail.chat.id) {
        // A late chat.get must not pull the owner back from another route, a
        // fresh New Chat draft, or a newer Chat selection.
        (model, none)
      } else {
      let chats = chats_with_detail(model.chats, detail)
      let details = details_with(model.chat_details, detail)
      let chat = chat_projection_from_detail(detail)
      let session_id = detail_session_id(detail)
      let workspace_id = match detail.active_agent_session {
        Some(session) =>
          if session.workspace_id == "" {
            chat_default_workspace_id(model)
          } else {
            session.workspace_id
          }
        None => chat_default_workspace_id(model)
      }
      let commands : Array[MachineCommand] = [
        ChatMessages(chat.id, "", 50),
      ]
      if session_id != "" {
        commands.push(ChatRead(chat.id, 0L))
      }
      (
        {
          ..model,
          page: Workroom,
          chats,
          chat_details: details,
          chats_loaded: true,
          selected_chat: chat.id,
          selected_bot: if chat.bot_id == "" {
            model.selected_bot
          } else {
            chat.bot_id
          },
          composing_new_chat: false,
          chat_messages_chat: chat.id,
          chat_messages_after: "",
          chat_messages_loaded: false,
          chat_read_cursor: 0L,
          chat_live_text: "",
          chat_session_state: chat.agent_state,
          chat_pending_decision: "",
          chat_workspace_id: workspace_id,
          chat_poll_in_flight: false,
          chat_messages_in_flight: true,
          chat_read_in_flight: session_id != "",
          chat_get_chat: "",
          chat_error: "",
          route_target: RouteChat(chat.id),
          route_note: "",
          chat_draft: { ..model.chat_draft, busy: false, message: "" },
          scroll_epoch: model.scroll_epoch + 1,
        },
        commands,
      )
      }
    ChatMessagesLoaded(chat_id, records, after, has_more) =>
      if chat_id != model.chat_messages_chat ||
        (model.page == Workroom &&
          model.selected_chat != "" &&
          chat_id != model.selected_chat) {
        (model, none)
      } else {
        let merged = merge_chat_messages(model.chat_messages, records)
        (
          {
            ..model,
            chat_messages: merged,
            chat_messages_chat: chat_id,
            chat_messages_after: if after != "" {
              after
            } else {
              last_chat_message_id(merged)
            },
            chat_messages_loaded: true,
            chat_poll_in_flight: false,
            chat_messages_in_flight: has_more,
            chat_error: "",
          },
          if has_more {
            [ChatMessages(chat_id, last_chat_message_id(merged), 50)]
          } else {
            none
          },
        )
      }
    ChatReadLoaded(chat_id, read) =>
      if chat_id != model.chat_messages_chat ||
        (model.page == Workroom &&
          model.selected_chat != "" &&
          chat_id != model.selected_chat) {
        (model, none)
      } else {
        let live = if read.cursor > model.chat_read_cursor {
          model.chat_live_text + read.text
        } else {
          model.chat_live_text
        }
        let chat = chat_by_id(model.chats, chat_id)
        let pending = if read.pending_decision == "" {
          match chat {
            Some(record) => record.pending_decision
            None => model.chat_pending_decision
          }
        } else {
          read.pending_decision
        }
        let pending_changed = pending != "" &&
          pending != model.chat_pending_decision
        (
          {
            ..model,
            chat_read_cursor: if read.cursor > model.chat_read_cursor {
              read.cursor
            } else {
              model.chat_read_cursor
            },
            chat_live_text: live,
            chat_session_state: if read.state == "" {
              model.chat_session_state
            } else {
              read.state
            },
            chat_pending_decision: pending,
            chat_poll_in_flight: false,
            chat_read_in_flight: false,
            chat_error: "",
          },
          if pending_changed { [DecisionList("")] } else { none },
        )
      }
    ChatSent(message, session) => {
      let messages = merge_chat_messages(model.chat_messages, [message])
      let chats = match chat_by_id(model.chats, message.chat_id) {
        Some(chat) =>
          chats_with_detail(
            model.chats,
            {
              chat: {
                id: chat.id,
                org_id: "",
                title: chat.title,
                project_id: chat.project_id,
                summary_ref: "",
                state: chat.state,
                created_at: chat.created_at,
                updated_at: message.created_at,
                archived_at: "",
              },
              participants: match chat_detail_by_id(
                model.chat_details,
                chat.id,
              ) {
                Some(detail) => detail.participants
                None => []
              },
              active_agent_session: Some(session),
              agent: match chat_detail_by_id(model.chat_details, chat.id) {
                Some(detail) => detail.agent
                None => None
              },
            },
          )
        None => model.chats
      }
      (
        {
          ..model,
          chat_messages: messages,
          chat_messages_chat: message.chat_id,
          chat_messages_after: last_chat_message_id(messages),
          chats,
          chat_session_state: session.state,
          chat_poll_in_flight: false,
          chat_messages_in_flight: true,
          chat_notice: tr(model.lang, "Message sent", "消息已发送"),
          chat_error: "",
        },
        [ChatMessages(message.chat_id, last_chat_message_id(model.chat_messages), 50)],
      )
    }
    ChatStopped(session, stopped) => {
      let mut chats = model.chats
      match chat_by_id(model.chats, session.chat_id) {
        Some(chat) =>
          chats = chats_with_detail(
            model.chats,
            {
              chat: {
                id: chat.id,
                org_id: "",
                title: chat.title,
                project_id: chat.project_id,
                summary_ref: "",
                state: chat.state,
                created_at: chat.created_at,
                updated_at: session.updated_at,
                archived_at: "",
              },
              participants: chat.participants.map(fn(bot_id) {
                @contracts.ChatParticipant::new(
                  chat_id=chat.id,
                  bot_id~,
                  added_at="",
                )
              }),
              active_agent_session: Some(session),
              agent: match chat_detail_by_id(model.chat_details, chat.id) {
                Some(detail) => detail.agent
                None => None
              },
            },
          )
        None => ()
      }
      (
        {
          ..model,
          chats,
          chat_session_state: session.state,
          chat_poll_in_flight: false,
          chat_messages_in_flight: false,
          chat_read_in_flight: false,
          chat_get_chat: session.chat_id,
          chat_notice: if stopped {
            tr(model.lang, "Agent session stopped", "智能体会话已停止")
          } else {
            tr(
              model.lang,
              "Agent session was already closed",
              "智能体会话此前已关闭",
            )
          },
          chat_error: "",
        },
        [ChatGet(session.chat_id)],
      )
    }
    ChatAgentSessionStarted(session) => {
      let mut chats = model.chats
      let mut details = model.chat_details
      match chat_by_id(model.chats, session.chat_id) {
        Some(chat) => {
          // `chat.create` returns before its AgentSession exists, so the first
          // `chat.agent_session.start` result is the point where the newly
          // created Chat learns which projected Agent it is running.
          let detail = @contracts.ChatDetail::new(
            chat={
              id: chat.id,
              org_id: "",
              title: chat.title,
              project_id: chat.project_id,
              summary_ref: "",
              state: chat.state,
              created_at: chat.created_at,
              updated_at: session.updated_at,
              archived_at: "",
            },
            participants=chat.participants.map(fn(bot_id) {
              @contracts.ChatParticipant::new(
                chat_id=chat.id,
                bot_id~,
                added_at="",
              )
            }),
            active_agent_session=Some(session),
            agent=agent_record_by_id(model.bot_agents, session.agent_id),
          )
          chats = chats_with_detail(model.chats, detail)
          details = details_with(model.chat_details, detail)
        }
        None => ()
      }
      (
        {
          ..model,
          chats,
          chat_details: details,
          chat_session_state: session.state,
          chat_workspace_id: if session.workspace_id == "" {
            model.chat_workspace_id
          } else {
            session.workspace_id
          },
          chat_read_cursor: 0L,
          chat_live_text: "",
          chat_pending_decision: "",
          chat_poll_in_flight: false,
          chat_messages_in_flight: false,
          chat_read_in_flight: model.selected_chat == session.chat_id,
          chat_get_chat: "",
          chat_error: "",
          chat_notice: tr(
            model.lang,
            "Agent session started for this Chat",
            "此对话的智能体会话已启动",
          ),
        },
        if model.selected_chat == session.chat_id {
          [ChatRead(session.chat_id, 0L)]
        } else {
          none
        },
      )
    }
    ChatPoll =>
      if !(model.page == Workroom || float_agent_visible(model)) ||
        model.composing_new_chat ||
        model.selected_chat == "" ||
        model.chat_poll_in_flight ||
        model.chat_messages_in_flight ||
        model.chat_read_in_flight {
        (model, none)
      } else {
        let chat_id = model.selected_chat
        let session_active = chat_session_active(model.chat_session_state)
        let commands : Array[MachineCommand] = [
          ChatMessages(chat_id, model.chat_messages_after, 50),
        ]
        if session_active {
          commands.push(ChatRead(chat_id, model.chat_read_cursor))
        }
        (
          {
            ..model,
            chat_poll_in_flight: !commands.is_empty(),
            chat_messages_in_flight: true,
            chat_read_in_flight: session_active,
          },
          commands,
        )
      }
    ChatStartSession =>
      if model.selected_chat == "" {
        (
          {
            ..model,
            chat_error: tr(
              model.lang,
              "Open a Chat before starting a session.",
              "启动会话前请先打开一个对话。",
            ),
          },
          none,
        )
      } else if model.chat_workspace_id == "" {
        (
          {
            ..model,
            chat_error: tr(
              model.lang,
              "Choose an open workspace before starting this Agent session.",
              "启动此智能体会话前请选择已打开的工作区。",
            ),
          },
          none,
        )
      } else {
        let agent_id = chat_agent_id_for(model, model.selected_chat)
        if agent_id == "" {
          (
            {
              ..model,
              chat_error: tr(
                model.lang,
                "This Chat has no bound Agent yet. Create or select one in the Bot page.",
                "此对话尚未绑定 Agent。请在 Bot 页创建或选择。",
              ),
            },
            none,
          )
        } else {
          (
            {
              ..model,
              chat_session_state: "starting",
              chat_error: "",
              chat_notice: tr(
                model.lang,
                "Starting the Agent session...",
                "正在启动智能体会话...",
              ),
            },
            [
              ChatAgentSessionStart(
                model.selected_chat,
                agent_id,
                model.chat_workspace_id,
              ),
            ],
          )
        }
      }
    ChatError(chat_id, message) => (
      {
        ..model,
        chat_error: message,
        chat_draft: if message.has_prefix("chat.") {
          { ..model.chat_draft, busy: false, message }
        } else {
          model.chat_draft
        },
        agent_draft: if message.has_prefix("bot.agent.") {
          { ..model.agent_draft, busy: false, message }
        } else {
          model.agent_draft
        },
        chat_poll_in_flight: if chat_id == model.selected_chat ||
          chat_id == "" {
          false
        } else {
          model.chat_poll_in_flight
        },
        chat_messages_in_flight: if chat_id == model.selected_chat ||
          chat_id == "" {
          false
        } else {
          model.chat_messages_in_flight
        },
        chat_read_in_flight: if chat_id == model.selected_chat ||
          chat_id == "" {
          false
        } else {
          model.chat_read_in_flight
        },
        chat_get_chat: if chat_id != "" &&
          (chat_id == model.selected_chat || chat_id == model.chat_get_chat) {
          ""
        } else {
          model.chat_get_chat
        },
      },
      none,
    )
    ChatNotice(text) => ({ ..model, chat_notice: text }, none)
    ChatDraftTitle(value) => (
      { ..model, chat_draft: { ..model.chat_draft, title: value } },
      none,
    )
    ChatDraftBot(bot_id) => {
      let project_id = model.chat_draft.project_id
      let allowed = if project_id == "" || bot_id == "" {
        true
      } else {
        bot_by_id(bots_in_project(model, project_id), bot_id) is Some(_)
      }
      if !allowed {
        (
          {
            ..model,
            chat_draft: {
              ..model.chat_draft,
              bot_id: "",
              agent_id: "",
              bot_picker_open: false,
              message: tr(
                model.lang,
                "This Bot has no active membership in the selected Project. Choose another Bot or clear the Project.",
                "此 Bot 在所选项目中没有有效成员资格。请选择其他 Bot 或清除项目。",
              ),
            },
            bot_agents: [],
            bot_agents_loaded: false,
          },
          none,
        )
      } else {
        let draft = {
          ..model.chat_draft,
          bot_id,
          bot_picker_open: false,
          agent_id: "",
          message: "",
        }
        (
          {
            ..model,
            chat_draft: draft,
            selected_bot: bot_id,
            bot_agents: [],
            bot_agents_loaded: false,
          },
          if bot_id == "" { none } else { [BotAgentList(bot_id)] },
        )
      }
    }
    ChatDraftProject(project_id) => {
      let members = if project_id == "" {
        model.bots.copy()
      } else {
        bots_in_project(model, project_id)
      }
      let current = bot_by_id(members, model.chat_draft.bot_id)
      let bot_id = match current {
        Some(record) => record.id
        None =>
          match members {
            [bot, ..] => bot.id
            [] => ""
          }
      }
      let draft = {
        ..model.chat_draft,
        project_id,
        project_picker_open: false,
        bot_id,
        agent_id: if bot_id == model.chat_draft.bot_id {
          model.chat_draft.agent_id
        } else {
          ""
        },
        message: if project_id != "" && members.is_empty() {
          tr(
            model.lang,
            "This Project has no Bot with active membership evidence yet. Create a project Chat on the host first, or choose No project in the Bot view.",
            "此项目尚无具备有效成员证据的 Bot。请先在主机上创建项目对话，或在 Bot 视图选择“无项目”。",
          )
        } else if project_id != "" && bot_id == "" {
          tr(
            model.lang,
            "Choose a Bot with membership in this Project.",
            "请选择在此项目中有成员资格的 Bot。",
          )
        } else {
          ""
        },
      }
      (
        {
          ..model,
          chat_draft: draft,
          selected_bot: draft.bot_id,
        },
        if draft.bot_id == "" { none } else { [BotAgentList(draft.bot_id)] },
      )
    }
    ChatDraftWorkspace(workspace_id) => (
      {
        ..model,
        chat_draft: {
          ..model.chat_draft,
          workspace_id,
          workspace_picker_open: false,
        },
        agent: { ..model.agent, workspace_id },
      },
      none,
    )
    ChatDraftAgent(agent_id) => (
      {
        ..model,
        chat_draft: {
          ..model.chat_draft,
          agent_id,
          agent_picker_open: false,
        },
      },
      none,
    )
    ChatDraftPicker(picker) => {
      let draft = match picker {
        ChatPickerBot => {
          ..model.chat_draft,
          bot_picker_open: !model.chat_draft.bot_picker_open,
        }
        ChatPickerProject => {
          ..model.chat_draft,
          project_picker_open: !model.chat_draft.project_picker_open,
        }
        ChatPickerWorkspace => {
          ..model.chat_draft,
          workspace_picker_open: !model.chat_draft.workspace_picker_open,
        }
        ChatPickerAgent => {
          ..model.chat_draft,
          agent_picker_open: !model.chat_draft.agent_picker_open,
        }
      }
      ({ ..model, chat_draft: draft }, none)
    }
    ChatCreateSubmit => {
      let draft = model.chat_draft
      let bot = bot_by_id(model.bots, draft.bot_id)
      let bot_name = match bot {
        Some(record) => bot_name(record)
        None => ""
      }
      if bot is None {
        (
          {
            ..model,
            chat_draft: {
              ..draft,
              message: tr(
                model.lang,
                "Choose a Bot before creating a Chat.",
                "创建对话前请选择 Bot。",
              ),
            },
          },
          none,
        )
      } else if draft.agent_id == "" ||
        !bot_agents_loaded_for(model, draft.bot_id) ||
        agent_for_bot(model.bot_agents, draft.agent_id) is None {
        (
          {
            ..model,
            chat_draft: {
              ..draft,
              message: tr(
                model.lang,
                "Choose an active Agent for this Bot.",
                "请为此 Bot 选择一个可用的 Agent。",
              ),
            },
          },
          [BotAgentList(draft.bot_id)],
        )
      } else if draft.workspace_id == "" {
        (
          {
            ..model,
            chat_draft: {
              ..draft,
              message: tr(
                model.lang,
                "Choose an open workspace so the Agent session can start.",
                "请选择已打开的工作区，以便启动智能体会话。",
              ),
            },
          },
          none,
        )
      } else {
        let title = if draft.title.trim() == "" {
          if bot_name == "" {
            tr(model.lang, "New Chat", "新对话")
          } else {
            tr(model.lang, "Chat with ", "与 ") +
            bot_name
          }
        } else {
          draft.title
        }
        let org_id = match bot {
          Some(record) => record.org_id
          None => ""
        }
        (
          {
            ..model,
            chat_draft: {
              ..draft,
              title,
              busy: true,
              message: tr(
                model.lang,
                "Creating the Chat and starting its Agent session...",
                "正在创建对话并启动智能体会话...",
              ),
            },
            chat_error: "",
          },
          [
            ChatCreate(
              draft.bot_id,
              title,
              draft.project_id,
              draft.agent_id,
              draft.workspace_id,
              org_id,
            ),
          ],
        )
      }
    }
    BotAgentsLoaded(bot_id, records) => (
      {
        ..model,
        bot_agents: records,
        bot_agents_bot: bot_id,
        bot_agents_loaded: true,
        chat_draft: if bot_id == model.chat_draft.bot_id &&
          model.chat_draft.agent_id == "" {
          let agent_id = selectable_agent_id(records)
          { ..model.chat_draft, agent_id }
        } else {
          model.chat_draft
        },
      },
      none,
    )
    AgentDraftName(value) => (
      { ..model, agent_draft: { ..model.agent_draft, name: value } },
      none,
    )
    AgentDraftSoftware(value) => (
      {
        ..model,
        agent_draft: {
          ..model.agent_draft,
          software: value,
          software_picker_open: false,
        },
      },
      none,
    )
    AgentDraftLaunch(value) => (
      { ..model, agent_draft: { ..model.agent_draft, launch_kind: value } },
      none,
    )
    AgentDraftCommand(value) => (
      { ..model, agent_draft: { ..model.agent_draft, command: value } },
      none,
    )
    AgentDraftArgs(value) => (
      { ..model, agent_draft: { ..model.agent_draft, args: value } },
      none,
    )
    AgentDraftSpecialty(value) => (
      { ..model, agent_draft: { ..model.agent_draft, specialty: value } },
      none,
    )
    AgentDraftSoftwarePicker(open) => (
      {
        ..model,
        agent_draft: {
          ..model.agent_draft,
          software_picker_open: open,
        },
      },
      none,
    )
    BotAgentCreateSubmit => {
      let draft = model.agent_draft
      let bot = bot_by_id(model.bots, model.selected_bot)
      let bot_id = model.selected_bot
      let args = split_command_args(draft.args)
      if bot is None {
        (
          {
            ..model,
            agent_draft: {
              ..draft,
              message: tr(
                model.lang,
                "Open a Bot before creating an Agent.",
                "创建 Agent 前请先打开一个 Bot。",
              ),
            },
          },
          none,
        )
      } else if draft.name.trim() == "" {
        (
          {
            ..model,
            agent_draft: {
              ..draft,
              message: tr(
                model.lang,
                "Agent name is required.",
                "Agent 名称为必填项。",
              ),
            },
          },
          none,
        )
      } else if draft.software.trim() == "" {
        (
          {
            ..model,
            agent_draft: {
              ..draft,
              message: tr(
                model.lang,
                "Choose the Agent software.",
                "请选择 Agent 软件。",
              ),
            },
          },
          none,
        )
      } else if draft.launch_kind == @contracts.RUNTIME_LAUNCH_COMMAND &&
        draft.command.trim() == "" {
        (
          {
            ..model,
            agent_draft: {
              ..draft,
              message: tr(
                model.lang,
                "A command launch needs a runtime command.",
                "命令启动需要运行时命令。",
              ),
            },
          },
          none,
        )
      } else {
        let org_id = match bot {
          Some(record) => record.org_id
          None => ""
        }
        (
          {
            ..model,
            agent_draft: {
              ..draft,
              busy: true,
              message: tr(
                model.lang,
                "Creating the Agent...",
                "正在创建 Agent...",
              ),
            },
          },
          [
            BotAgentCreate(
              bot_id,
              org_id,
              draft.name,
              draft.software,
              draft.launch_kind,
              args,
              draft.command,
            ),
          ],
        )
      }
    }
    BotAgentMutated(record) => {
      let mut agents = model.bot_agents
      if record.bot_id == model.bot_agents_bot {
        let out : Array[@contracts.AgentRecord] = []
        let mut replaced = false
        for current in agents {
          if current.id == record.id {
            out.push(record)
            replaced = true
          } else {
            out.push(current)
          }
        }
        if !replaced {
          out.push(record)
        }
        agents = out
      }
      (
        {
          ..model,
          bot_agents: agents,
          agent_draft: {
            ..model.agent_draft,
            name: "",
            command: "",
            args: "",
            specialty: "",
            busy: false,
            message: (if record.state == "" {
              @contracts.AGENT_LIFECYCLE_ACTIVE
            } else {
              record.state
            }) +
            tr(model.lang, " · Agent saved", " · Agent 已保存"),
          },
          chat_notice: tr(
            model.lang,
            "Agent record updated",
            "Agent 记录已更新",
          ),
        },
        [BotAgentList(model.selected_bot)],
      )
    }
    SuspendBotAgent(agent_id) => (
      {
        ..model,
        chat_notice: tr(model.lang, "Suspending Agent...", "正在暂停 Agent..."),
      },
      [BotAgentSuspend(agent_id, "owner request")],
    )
    RetireBotAgent(agent_id) => (
      {
        ..model,
        chat_notice: tr(model.lang, "Retiring Agent...", "正在停用 Agent..."),
      },
      [BotAgentRetire(agent_id, "owner request")],
    )
    BotProjectFilter(project_id) => (
      {
        ..model,
        bot_project_filter: project_id,
        bot_project_filter_open: false,
      },
      [ChatList("", "")],
    )
    BotProjectFilterPicker(open) => (
      { ..model, bot_project_filter_open: open },
      none,
    )
    SelectProject(project_id) => (
      {
        ..model,
        page: Manage,
        manage_tab: ManageProjects,
        project: {
          ..model.project,
          selected_project: project_id,
          project_picker_open: false,
          chat_bot_filter: "",
          chat_bot_picker_open: false,
        },
        route_target: RouteProjects(project_id),
        route_note: "",
      },
      [ChatList("", "")],
    )
    ProjectCatalogLoaded(records) => {
      let route_project = match model.route_target {
        RouteProjects(id) => id
        _ => ""
      }
      let mut selected = model.project.selected_project
      if route_project != "" && project_by_id(records, route_project) is Some(_) {
        selected = route_project
      } else if selected != "" && project_by_id(records, selected) is None {
        selected = ""
      }
      if selected == "" && !records.is_empty() {
        selected = records[0].id
      }
      let route_target = match model.route_target {
        RouteProjects(id) if id != "" && project_by_id(records, id) is None =>
          RouteProjects("")
        _ => model.route_target
      }
      (
        {
          ..model,
          project: {
            ..model.project,
            projects: records,
            projects_loaded: true,
            selected_project: selected,
          },
          route_target,
        },
        if selected == "" {
          none
        } else {
          [ChatList("", "")]
        },
      )
    }
    ProjectCatalogPicker(open) => (
      { ..model, project: { ..model.project, project_picker_open: open } },
      none,
    )
    ProjectChatBotFilter(bot_id) => (
      {
        ..model,
        project: {
          ..model.project,
          chat_bot_filter: bot_id,
          chat_bot_picker_open: false,
        },
      },
      [ChatList("", "")],
    )
    ProjectChatBotPicker(open) => (
      { ..model, project: { ..model.project, chat_bot_picker_open: open } },
      none,
    )
    RouteArrived(target) => {
      let mut page = model.page
      let route_target = target
      let mut selected_chat = model.selected_chat
      let mut selected_bot = model.selected_bot
      let mut selected_project = model.project.selected_project
      match target {
        RouteWorkroom => {
          page = Workroom
          selected_chat = ""
        }
        RouteChat(id) => {
          page = Workroom
          selected_chat = id
        }
        RouteBot(id) => {
          page = BotDetail
          selected_bot = if id == "" {
            active_bot_identity(model).id
          } else {
            id
          }
        }
        RouteProjects(_) => {
          page = Manage
        }
      }
      match target {
        RouteProjects(id) =>
          selected_project = if id == "" {
            selected_project
          } else {
            id
          }
        _ => ()
      }
      match target {
        RouteChat(id) => selected_bot = match chat_by_id(model.chats, id) {
          Some(chat) => chat.bot_id
          None => selected_bot
        }
        _ => ()
      }
      let commands : Array[MachineCommand] = match target {
        RouteChat(id) => [
          BotList,
          ChatList("", ""),
          ProjectCatalog,
          ChatGet(id),
        ]
        RouteBot(_) => [
          BotList,
          ChatList("", ""),
          ProjectCatalog,
          BotAgentList(selected_bot),
        ]
        RouteProjects(_) => [ProjectCatalog, BotList, ChatList("", "")]
        RouteWorkroom => [BotList, ChatList("", ""), ProjectCatalog]
      }
      (
        {
          ..model,
          page,
          manage_tab: match target {
            RouteProjects(_) => ManageProjects
            _ => model.manage_tab
          },
          selected_chat,
          selected_bot,
          project: {
            ..model.project,
            selected_project,
          },
          composing_new_chat: false,
          chat_get_chat: match target {
            RouteChat(id) => id
            _ => model.chat_get_chat
          },
          chat_error: "",
          route_target,
          route_note: "",
          scroll_epoch: model.scroll_epoch + 1,
        },
        commands,
      )
    }
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
      let same_workspace = match model.project.workspace {
        Some(current) => current.id == record.id
        None => false
      }
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
      let commands : Array[MachineCommand] = if !same_workspace &&
        model.project.terminal_id != "" {
        [ProjectCloseTerminal(model.project.terminal_id)]
      } else {
        none
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
          terminal_id: if same_workspace {
            model.project.terminal_id
          } else {
            ""
          },
          terminal_text: if same_workspace {
            model.project.terminal_text
          } else {
            ""
          },
          terminal_input: if same_workspace {
            model.project.terminal_input
          } else {
            ""
          },
          terminal_cursor: if same_workspace {
            model.project.terminal_cursor
          } else {
            0L
          },
          terminal_focus: if same_workspace {
            model.project.terminal_focus
          } else {
            false
          },
          terminal_state: if same_workspace {
            model.project.terminal_state
          } else {
            TerminalClosed
          },
          terminal_eof: if same_workspace {
            model.project.terminal_eof
          } else {
            false
          },
          terminal_error: if same_workspace {
            model.project.terminal_error
          } else {
            ""
          },
          terminal_read_in_flight: if same_workspace {
            model.project.terminal_read_in_flight
          } else {
            false
          },
          terminal_history: if same_workspace {
            model.project.terminal_history
          } else {
            []
          },
          busy: false,
          message: tr(model.lang, "opened ", "已打开 ") + record.root,
        },
      }
      (apply_workspace_defaults(opened, opened.project.workspaces), commands)
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
    ProjectTerminalFocus =>
      match model.project.workspace {
        Some(record) => {
          let should_open = model.project.terminal_id == "" &&
            model.project.terminal_state == TerminalClosed
          let commands : Array[MachineCommand] = if should_open {
            [ProjectOpenTerminal(record.id)]
          } else {
            none
          }
          (
            {
              ..model,
              page: Manage,
              manage_tab: ManageProjects,
              scroll_epoch: model.scroll_epoch + 1,
              project: {
                ..model.project,
                terminal_focus: true,
                terminal_state: if should_open {
                  TerminalOpening
                } else {
                  model.project.terminal_state
                },
                // Re-entering the focused view must not overlap a read that
                // was already in flight when the user left the page.
                terminal_read_in_flight: model.project.terminal_read_in_flight,
              },
            },
            commands,
          )
        }
        None =>
          (
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
    ProjectTerminalBack =>
      (
        {
          ..model,
          project: { ..model.project, terminal_focus: false },
          scroll_epoch: model.scroll_epoch + 1,
        },
        none,
      )
    ProjectTerminalReconnect => {
      let old_session = model.project.terminal_id
      let commands : Array[MachineCommand] = []
      if old_session != "" {
        commands.push(ProjectCloseTerminal(old_session))
      }
      match model.project.workspace {
        Some(record) => {
          commands.push(ProjectOpenTerminal(record.id))
          (
            {
              ..model,
              page: Manage,
              manage_tab: ManageProjects,
              project: {
                ..model.project,
                terminal_id: "",
                terminal_text: "",
                terminal_cursor: 0L,
                terminal_focus: true,
                terminal_state: TerminalOpening,
                terminal_eof: false,
                terminal_error: "",
                terminal_read_in_flight: false,
                terminal_scroll_epoch: model.project.terminal_scroll_epoch + 1,
              },
            },
            commands,
          )
        }
        None =>
          (
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
            commands,
          )
      }
    }
    ProjectTerminalClear =>
      (
        {
          ..model,
          project: {
            ..model.project,
            terminal_text: "",
            terminal_scroll_epoch: model.project.terminal_scroll_epoch + 1,
          },
        },
        none,
      )
    ProjectTerminalClose => {
      let commands : Array[MachineCommand] = if model.project.terminal_id != "" {
        [ProjectCloseTerminal(model.project.terminal_id)]
      } else {
        none
      }
      (
        {
          ..model,
          project: {
            ..model.project,
            terminal_id: "",
            terminal_text: "",
            terminal_input: "",
            terminal_cursor: 0L,
            terminal_eof: false,
            terminal_error: "",
            terminal_read_in_flight: false,
            terminal_state: TerminalClosed,
            terminal_scroll_epoch: model.project.terminal_scroll_epoch + 1,
          },
        },
        commands,
      )
    }
    ProjectTerminalStop =>
      if model.project.terminal_id != "" &&
        model.project.terminal_state == TerminalRunning {
        (model, [ProjectTerminalWrite(model.project.terminal_id, "\u{3}")])
      } else {
        (model, none)
      }
    ProjectTerminalPoll =>
      if terminal_should_poll(model) && !model.project.terminal_read_in_flight {
        (
          {
            ..model,
            project: { ..model.project, terminal_read_in_flight: true },
          },
          [
            ProjectTerminalRead(
              model.project.terminal_id,
              model.project.terminal_cursor,
            ),
          ],
        )
      } else {
        (model, none)
      }
    ProjectTerminalOpened(session_id, text, cursor, eof) =>
      if session_id == "" {
        (
          {
            ..model,
            project: {
              ..model.project,
              terminal_state: TerminalFailed,
              terminal_error: "terminal.open: missing session_id",
              terminal_read_in_flight: false,
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
              terminal_id: session_id,
              terminal_text: text,
              terminal_cursor: cursor,
              terminal_state: if eof {
                TerminalEnded
              } else {
                TerminalRunning
              },
              terminal_eof: eof,
              terminal_error: "",
              terminal_read_in_flight: false,
              terminal_scroll_epoch: model.project.terminal_scroll_epoch + 1,
              busy: false,
            },
          },
          none,
        )
      }
    ProjectTerminalOutput(session_id, cursor, text, eof) =>
      if session_id != model.project.terminal_id {
        (model, none)
      } else {
        let advanced = cursor > model.project.terminal_cursor
        let next_text = terminal_text_after_read(
          model.project.terminal_text,
          model.project.terminal_cursor,
          cursor,
          text,
        )
        let next_eof = eof || model.project.terminal_eof
        (
          {
            ..model,
            project: {
              ..model.project,
              terminal_text: next_text,
              terminal_cursor: if advanced {
                cursor
              } else {
                model.project.terminal_cursor
              },
              terminal_state: if next_eof {
                TerminalEnded
              } else {
                TerminalRunning
              },
              terminal_eof: next_eof,
              terminal_read_in_flight: false,
              terminal_scroll_epoch: if advanced && text != "" {
                model.project.terminal_scroll_epoch + 1
              } else {
                model.project.terminal_scroll_epoch
              },
            },
          },
          none,
        )
      }
    ProjectTerminalFailed(session_id, error) =>
      if session_id != "" && session_id != model.project.terminal_id {
        (model, none)
      } else {
        (
          {
            ..model,
            project: {
              ..model.project,
              terminal_state: TerminalFailed,
              terminal_error: error,
              terminal_read_in_flight: false,
            },
          },
          none,
        )
      }
    ProjectTerminalHistory(command) =>
      (
        { ..model, project: { ..model.project, terminal_input: command } },
        none,
      )
    // A selectable transcript is rendered with a text area. Edits are
    // discarded; leaving `terminal_text` unchanged makes a read-only view
    // without reaching into MoUI's caret internals.
    ProjectTerminalTranscriptEdited(_text) => (model, none)
    ProjectTerminalSend => {
      let line = model.project.terminal_input
      if line == "" {
        (model, none)
      } else if model.project.terminal_id != "" &&
        model.project.terminal_state == TerminalRunning {
        (
          {
            ..model,
            project: {
              ..model.project,
              terminal_input: "",
              terminal_history: terminal_history_push(
                model.project.terminal_history,
                line,
              ),
            },
          },
          [
            ProjectTerminalWrite(
              model.project.terminal_id,
              terminal_command_payload(line),
            ),
          ],
        )
      } else {
        (
          {
            ..model,
            project: {
              ..model.project,
              message: tr(
                model.lang,
                "terminal is not running; reconnect first",
                "终端未运行，请先重新连接",
              ),
            },
          },
          none,
        )
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
        chat_workspace_id: if model.selected_chat != "" &&
          !chat_session_active(model.chat_session_state) {
          value
        } else {
          model.chat_workspace_id
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
              launch_prompt: model.agent.prompt,
              sent_prompts: [],
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
            let sent = model.agent.sent_prompts.copy()
            sent.push(model.agent.input)
            (
              {
                ..model,
                agent: {
                  ..model.agent,
                  input: "",
                  sent_prompts: sent,
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
    ComposerSend => {
      let prompt = model.agent.input.trim().to_owned()
      if model.composing_new_chat {
        update_full(model, ChatCreateSubmit)
      } else if model.selected_chat != "" &&
        chat_by_id(model.chats, model.selected_chat) is Some(_) {
        if prompt == "" {
          (model, none)
        } else if !chat_session_active(model.chat_session_state) {
          (
            {
              ..model,
              chat_error: tr(
                model.lang,
                "The Agent session is not active. Start it before sending.",
                "智能体会话未运行。请先启动会话再发送。",
              ),
            },
            none,
          )
        } else {
          (
            {
              ..model,
              agent: { ..model.agent, input: "", state_text: "running" },
              chat_notice: tr(
                model.lang,
                "Sending to the Chat...",
                "正在发送到对话...",
              ),
              chat_error: "",
            },
            [ChatSend(model.selected_chat, prompt)],
          )
        }
      } else if prompt == "" {
        (model, none)
      } else {
        match model.agent.session {
          Some(record) =>
            if model.composing_new_chat {
              (
                {
                  ..model,
                  composing_new_chat: false,
                  selected_chat: "",
                  agent: {
                    ..model.agent,
                    input: "",
                    launch_prompt: prompt,
                    sent_prompts: [],
                    state_text: "starting",
                    stop_reason: "",
                    message: tr(
                      model.lang,
                      "starting a new Chat...",
                      "正在启动新对话...",
                    ),
                  },
                },
                [
                  AgentStart(
                    model.agent.agent_id,
                    model.agent.mode,
                    model.agent.workspace_id,
                    model.agent.worktree_id,
                    prompt,
                  ),
                ],
              )
            } else {
              let sent = model.agent.sent_prompts.copy()
              sent.push(prompt)
              (
                {
                  ..model,
                  agent: {
                    ..model.agent,
                    input: "",
                    sent_prompts: sent,
                    state_text: "running",
                    message: tr(model.lang, "prompt sent", "提示词已发送"),
                  },
                },
                [AgentSend(record.id, prompt)],
              )
            }
          None =>
            (
              {
                ..model,
                composing_new_chat: false,
                selected_chat: "",
                agent: {
                  ..model.agent,
                  input: "",
                  launch_prompt: prompt,
                  sent_prompts: [],
                  state_text: "starting",
                  stop_reason: "",
                  message: tr(
                    model.lang,
                    "starting a new Chat...",
                    "正在启动新对话...",
                  ),
                },
              },
              [
                AgentStart(
                  model.agent.agent_id,
                  model.agent.mode,
                  model.agent.workspace_id,
                  model.agent.worktree_id,
                  prompt,
                ),
              ],
            )
        }
      }
    }
    AgentStopSession =>
      if model.selected_chat != "" &&
        chat_by_id(model.chats, model.selected_chat) is Some(_) {
        (
          {
            ..model,
            chat_session_state: "ending",
            chat_notice: tr(
              model.lang,
              "Stopping the Chat Agent session...",
              "正在停止对话的智能体会话...",
            ),
          },
          [
            ChatStop(
              model.selected_chat,
              match chat_by_id(model.chats, model.selected_chat) {
                Some(record) => record.agent_session_id
                None => ""
              },
            ),
          ],
        )
      } else {
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
        composing_new_chat: false,
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
          launch_prompt: model.agent.launch_prompt,
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
    ToggleFloatWorkspace => {
      let closing_terminal = float_terminal_visible(model)
      let float = {
        ..model.float,
        open: !model.float.open,
        menu_open: false,
        dragging: false,
        resizing: false,
      }
      let project = if closing_terminal && model.page != Manage {
        { ..model.project, terminal_focus: false }
      } else {
        model.project
      }
      ({ ..model, float: float_workspace_clamped(float), project }, none)
    }
    CloseFloatWorkspace => {
      let closing_terminal = float_terminal_visible(model)
      let project = if closing_terminal && model.page != Manage {
        { ..model.project, terminal_focus: false }
      } else {
        model.project
      }
      (
        {
          ..model,
          float: {
            ..model.float,
            open: false,
            menu_open: false,
            dragging: false,
            resizing: false,
          },
          project,
        },
        none,
      )
    }
    FloatSelectTab(tab_id) =>
      match float_tab_by_id(model.float, tab_id) {
        Some(tab) => {
          let project = if tab.kind == FloatTerminal &&
            model.project.workspace is Some(_) {
            { ..model.project, terminal_focus: true }
          } else {
            model.project
          }
          (
            {
              ..model,
              float: {
                ..model.float,
                active_tab: tab_id,
                menu_open: false,
              },
              project,
            },
            none,
          )
        }
        None => (model, none)
      }
    FloatCloseTab(tab_id) => {
      let closing_terminal = match float_tab_by_id(model.float, tab_id) {
        Some(tab) => tab.kind == FloatTerminal
        None => false
      }
      let float = float_close_tab(model.float, tab_id)
      let project = if closing_terminal && model.page != Manage {
        { ..model.project, terminal_focus: false }
      } else {
        model.project
      }
      ({ ..model, float, project }, none)
    }
    FloatNewNote => (
      { ..model, float: float_new_note(model.float, model.lang) },
      none,
    )
    FloatNewAgent => (
      { ..model, float: float_new_kind_tab(model.float, FloatAgent) },
      none,
    )
    FloatNewTerminal => {
      let float = float_new_kind_tab(model.float, FloatTerminal)
      let commands : Array[MachineCommand] = []
      let project = match model.project.workspace {
        Some(record) => {
          let should_open = model.project.terminal_id == "" &&
            model.project.terminal_state == TerminalClosed
          if should_open {
            commands.push(ProjectOpenTerminal(record.id))
          }
          {
            ..model.project,
            terminal_focus: true,
            terminal_state: if should_open {
              TerminalOpening
            } else {
              model.project.terminal_state
            },
          }
        }
        None => model.project
      }
      let float = if model.project.workspace is None {
        {
          ..float,
          message: tr(
            model.lang,
            "Open a project first, then open its terminal.",
            "请先打开项目，然后打开其终端。",
          ),
        }
      } else {
        float
      }
      ({ ..model, float, project }, commands)
    }
    FloatMenu(open) => (
      { ..model, float: { ..model.float, menu_open: open } },
      none,
    )
    FloatNoteTitleDraft(value) =>
      match float_active_note(model.float) {
        Some(note) =>
          match float_note_title_problem(value) {
            Some(problem) => (
              {
                ..model,
                float: { ..model.float, message: problem },
              },
              none,
            )
            None => {
              let float = float_note_updated(
                model.float,
                note.id,
                fn(current) {
                  {
                    ..current,
                    title: value,
                    state: FloatNoteSaving,
                    revision: current.revision + 1,
                  }
                },
              )
              (
                {
                  ..model,
                  float: { ..float, message: "" },
                },
                none,
              )
            }
          }
        None => (model, none)
      }
    FloatNoteContentDraft(value) =>
      match float_active_note(model.float) {
        Some(note) => {
          let float = float_note_updated(
            model.float,
            note.id,
            fn(current) {
              {
                ..current,
                content: value,
                state: FloatNoteSaving,
                revision: current.revision + 1,
              }
            },
          )
          (
            {
              ..model,
              float: { ..float, message: "" },
            },
            none,
          )
        }
        None => (model, none)
      }
    FloatNoteStored(note_id, revision, ok, error) => {
      let float = float_note_updated(
        model.float,
        note_id,
        fn(current) {
          if current.revision == revision {
            {
              ..current,
              state: if ok {
                FloatNoteSaved
              } else {
                FloatNoteFailed(error)
              },
            }
          } else {
            current
          }
        },
      )
      ({ ..model, float }, none)
    }
    FloatWorkspaceRestored(restore) => {
      if model.float.loaded {
        (model, none)
      } else if restore.has_state {
        let float = {
          ..model.float,
          x: restore.x,
          y: restore.y,
          width: restore.width,
          height: restore.height,
          active_tab: restore.active_tab,
          tabs: restore.tabs,
          notes: restore.notes,
          next_id: restore.next_id,
          loaded: true,
          menu_open: false,
          message: restore.message,
        }
        ({ ..model, float: float_workspace_clamped(float) }, none)
      } else {
        (
          {
            ..model,
            float: {
              ..model.float,
              loaded: true,
              message: restore.message,
            },
          },
          none,
        )
      }
    }
    FloatHeaderDrag(phase, dx, dy) =>
      match phase {
        @core.DragGesturePhase::Started => (
          {
            ..model,
            float: {
              ..model.float,
              dragging: true,
              drag_origin_x: model.float.x,
              drag_origin_y: model.float.y,
            },
          },
          none,
        )
        @core.DragGesturePhase::Changed =>
          if model.float.dragging {
            let float = float_workspace_clamped({
              ..model.float,
              x: model.float.drag_origin_x + dx,
              y: model.float.drag_origin_y + dy,
            })
            ({ ..model, float }, none)
          } else {
            (model, none)
          }
        @core.DragGesturePhase::Ended | @core.DragGesturePhase::Cancelled => (
          { ..model, float: { ..model.float, dragging: false } },
          none,
        )
        _ => (model, none)
      }
    FloatResizeDrag(phase, dx, dy) =>
      match phase {
        @core.DragGesturePhase::Started => (
          {
            ..model,
            float: {
              ..model.float,
              resizing: true,
              resize_origin_width: model.float.width,
              resize_origin_height: model.float.height,
            },
          },
          none,
        )
        @core.DragGesturePhase::Changed =>
          if model.float.resizing {
            let width = (model.float.resize_origin_width + dx).clamp(
              min=float_min_width,
              max=float_max_width,
            )
            let height = (model.float.resize_origin_height + dy).clamp(
              min=float_min_height,
              max=float_max_height,
            )
            let float = float_workspace_clamped({
              ..model.float,
              width,
              height,
            })
            ({ ..model, float }, none)
          } else {
            (model, none)
          }
        @core.DragGesturePhase::Ended | @core.DragGesturePhase::Cancelled => (
          { ..model, float: { ..model.float, resizing: false } },
          none,
        )
        _ => (model, none)
      }
    FloatOpenTerminal => {
      let commands : Array[MachineCommand] = []
      let project = match model.project.workspace {
        Some(record) => {
          let should_open = model.project.terminal_id == "" &&
            model.project.terminal_state == TerminalClosed
          if should_open {
            commands.push(ProjectOpenTerminal(record.id))
          }
          {
            ..model.project,
            terminal_focus: true,
            terminal_state: if should_open {
              TerminalOpening
            } else {
              model.project.terminal_state
            },
          }
        }
        None => model.project
      }
      let float = if model.project.workspace is None {
        {
          ..model.float,
          message: tr(
            model.lang,
            "Open a project first, then open its terminal.",
            "请先打开项目，然后打开其终端。",
          ),
        }
      } else {
        { ..model.float, message: "" }
      }
      ({ ..model, float, project }, commands)
    }
    FloatTerminalReconnect => {
      let commands : Array[MachineCommand] = []
      if model.project.terminal_id != "" {
        commands.push(ProjectCloseTerminal(model.project.terminal_id))
      }
      match model.project.workspace {
        Some(record) => {
          commands.push(ProjectOpenTerminal(record.id))
          (
            {
              ..model,
              project: {
                ..model.project,
                terminal_id: "",
                terminal_text: "",
                terminal_cursor: 0L,
                terminal_focus: true,
                terminal_state: TerminalOpening,
                terminal_eof: false,
                terminal_error: "",
                terminal_read_in_flight: false,
                terminal_scroll_epoch: model.project.terminal_scroll_epoch + 1,
              },
            },
            commands,
          )
        }
        None => (model, commands)
      }
    }
    FloatNoop => (model, none)
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
