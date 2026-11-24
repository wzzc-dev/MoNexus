///|
/// Five shell pages. M1 only switches between them; the content is a
/// placeholder for M2-M5 business screens.
pub(all) enum Page {
  Home
  Machines
  Tasks
  Search
  Settings
}

///|
pub fn Page::label(self : Page) -> String {
  match self {
    Home => "Home"
    Machines => "Machines"
    Tasks => "Tasks"
    Search => "Search"
    Settings => "Settings"
  }
}

///|
pub fn Page::from_label(value : String) -> Page {
  match value.to_lower() {
    "machines" => Machines
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
pub struct Model {
  page : Page
  host : HostProjection
  machines : Array[@contracts.MachineRecord]
  machines_loaded : Bool
  machine_busy : String
  machine_message : String
  draft : MachineDraft
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
/// Pure update: returns the next model plus the commands the command worker
/// should run. `update` below is the model-only view used by tests.
pub fn update_full(
  model : Model,
  msg : Msg,
) -> (Model, Array[MachineCommand]) {
  let none : Array[MachineCommand] = []
  match msg {
    SelectPage(page) => ({ ..model, page }, none)
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
      ({ ..model, host }, none)
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
  }
}

///|
pub fn update(model : Model, msg : Msg) -> Model {
  let (next, _) = update_full(model, msg)
  next
}
