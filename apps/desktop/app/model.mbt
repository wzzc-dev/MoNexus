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
pub struct Model {
  page : Page
  host : HostProjection
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
  { page, host }
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
}

///|
pub fn update(model : Model, msg : Msg) -> Model {
  match msg {
    SelectPage(page) => { ..model, page }
    LinkConnecting => {
      let host = {
        ..model.host,
        link: Connecting,
        last_error: "",
      }
      { ..model, host }
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
      { ..model, host }
    }
    LinkOffline(reason) => {
      let host = {
        ..model.host,
        link: Offline,
        last_error: reason,
      }
      { ..model, host }
    }
    EventArrived(event_type, seq) => {
      let host = {
        ..model.host,
        event_seq: seq,
        event_count: model.host.event_count + 1,
        last_event: event_type,
      }
      { ..model, host }
    }
  }
}
