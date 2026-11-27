///|
/// Floating workspace overlay: a small parallel surface that can stay open
/// beside the current Chat, Bot page or Manage tab. It owns presentation state
/// and one local note store; it never duplicates the Agent or terminal
/// protocols.

///|
pub const FLOAT_WORKSPACE_SCHEMA_VERSION : Int = 1

///|
pub const FLOAT_WORKSPACE_STATE_FILE : String = "workspace.json"

///|
pub const FLOAT_WORKSPACE_DIR : String = "floating"

///|
pub const FLOAT_WORKSPACE_NOTES_DIR : String = "notes"

///|
pub const FLOAT_NOTE_DEBOUNCE_MS : Int = 300

///|
let float_min_x : Double = 240.0

///|
let float_min_y : Double = 56.0

///|
let float_min_width : Double = 480.0

///|
let float_max_width : Double = 1024.0

///|
let float_min_height : Double = 340.0

///|
let float_max_height : Double = 736.0

///|
let float_window_right : Double = 1272.0

///|
let float_window_bottom : Double = 792.0

///|
#derive(Eq)
pub(all) enum FloatTabKind {
  FloatNote
  FloatAgent
  FloatTerminal
}

///|
pub fn FloatTabKind::value(self : FloatTabKind) -> String {
  match self {
    FloatNote => "note"
    FloatAgent => "agent"
    FloatTerminal => "terminal"
  }
}

///|
pub fn float_tab_kind_from_value(value : String) -> FloatTabKind? {
  match value.to_lower() {
    "note" => Some(FloatNote)
    "agent" => Some(FloatAgent)
    "terminal" => Some(FloatTerminal)
    _ => None
  }
}

///|
#derive(Eq)
pub(all) enum FloatNoteState {
  FloatNoteSaved
  FloatNoteSaving
  FloatNoteFailed(String)
}

///|
pub(all) struct FloatTab {
  id : String
  kind : FloatTabKind
  note_id : String
}

///|
pub(all) struct FloatNote {
  id : String
  title : String
  file_name : String
  content : String
  state : FloatNoteState
  revision : Int
}

///|
pub(all) struct FloatWorkspace {
  open : Bool
  x : Double
  y : Double
  width : Double
  height : Double
  active_tab : String
  tabs : Array[FloatTab]
  notes : Array[FloatNote]
  next_id : Int
  menu_open : Bool
  loaded : Bool
  dragging : Bool
  drag_origin_x : Double
  drag_origin_y : Double
  resizing : Bool
  resize_origin_width : Double
  resize_origin_height : Double
  message : String
}

///|
pub(all) struct FloatNoteMeta {
  id : String
  title : String
  file_name : String
}

///|
pub(all) struct FloatNoteWrite {
  note_id : String
  file_name : String
  content : String
  revision : Int
  state_json : String
}

///|
pub(all) struct FloatWorkspaceRestore {
  has_state : Bool
  x : Double
  y : Double
  width : Double
  height : Double
  active_tab : String
  tabs : Array[FloatTab]
  notes : Array[FloatNote]
  next_id : Int
  message : String
}

///|
pub(all) enum FloatPersistRequest {
  FloatRestoreRequest
  FloatNoteRequest(FloatNoteWrite)
  FloatStateRequest(String)
}

///|
pub fn float_workspace_new(lang : Lang) -> FloatWorkspace {
  let note = {
    id: "n1",
    title: tr(lang, "Note 1", "笔记 1"),
    file_name: "note-n1.md",
    content: "",
    state: FloatNoteSaved,
    revision: 0,
  }
  let tab = { id: "tab-n1", kind: FloatNote, note_id: "n1" }
  {
    open: false,
    x: 248.0,
    y: 64.0,
    width: 904.0,
    height: 620.0,
    active_tab: tab.id,
    tabs: [tab],
    notes: [note],
    next_id: 2,
    menu_open: false,
    loaded: false,
    dragging: false,
    drag_origin_x: 0.0,
    drag_origin_y: 0.0,
    resizing: false,
    resize_origin_width: 904.0,
    resize_origin_height: 620.0,
    message: "",
  }
}

///|
pub fn FloatWorkspace::new(lang : Lang) -> FloatWorkspace {
  float_workspace_new(lang)
}

///|
pub fn float_workspace_clamped(workspace : FloatWorkspace) -> FloatWorkspace {
  let width = workspace.width.clamp(min=float_min_width, max=float_max_width)
  let height = workspace.height.clamp(
    min=float_min_height,
    max=float_max_height,
  )
  let max_x = (float_window_right - width).max(float_min_x)
  let max_y = (float_window_bottom - height).max(float_min_y)
  {
    ..workspace,
    x: workspace.x.clamp(min=float_min_x, max=max_x),
    y: workspace.y.clamp(min=float_min_y, max=max_y),
    width,
    height,
  }
}

///|
pub fn float_note_title_problem(title : String) -> String? {
  if title.length() > 120 {
    return Some("Note title is too long (maximum 120 characters).")
  }
  if title.contains("..") {
    return Some("Note title cannot contain \"..\".")
  }
  for ch in title {
    if ch == '/' || ch == '\\' || ch == '\n' || ch == '\r' {
      return Some("Note title cannot contain path separators.")
    }
  }
  None
}

///|
pub fn float_note_file_name(note_id : String) -> String? {
  if note_id == "" || note_id.contains("/") || note_id.contains("\\") ||
    note_id.contains("..") || note_id == "." {
    return None
  }
  for ch in note_id {
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '-' ||
      ch == '_'
    if !ok {
      return None
    }
  }
  Some("note-" + note_id + ".md")
}

///|
pub fn float_note_path_in(
  notes_dir : String,
  file_name : String,
) -> String? {
  if file_name == "" || file_name == "." || file_name == ".." ||
    file_name.contains("/") || file_name.contains("\\") ||
    file_name.contains("..") || !file_name.has_suffix(".md") {
    return None
  }
  Some(notes_dir + "/" + file_name)
}

///|
pub fn float_notes_dir_in(config_dir : String) -> String {
  config_dir + "/" + FLOAT_WORKSPACE_DIR + "/" + FLOAT_WORKSPACE_NOTES_DIR
}

///|
pub fn float_config_dir() -> String {
  theme_config_dir()
}

///|
pub fn float_notes_dir() -> String {
  float_notes_dir_in(float_config_dir())
}

///|
pub fn float_state_path_in(config_dir : String) -> String {
  config_dir + "/" + FLOAT_WORKSPACE_DIR + "/" + FLOAT_WORKSPACE_STATE_FILE
}

///|
pub fn float_state_path() -> String {
  float_state_path_in(float_config_dir())
}

///|
pub fn float_tab_by_id(
  workspace : FloatWorkspace,
  tab_id : String,
) -> FloatTab? {
  for tab in workspace.tabs {
    if tab.id == tab_id {
      return Some(tab)
    }
  }
  None
}

///|
pub fn float_note_by_id(
  workspace : FloatWorkspace,
  note_id : String,
) -> FloatNote? {
  for note in workspace.notes {
    if note.id == note_id {
      return Some(note)
    }
  }
  None
}

///|
pub fn float_active_tab(workspace : FloatWorkspace) -> FloatTab? {
  float_tab_by_id(workspace, workspace.active_tab)
}

///|
pub fn float_active_note(workspace : FloatWorkspace) -> FloatNote? {
  match float_active_tab(workspace) {
    Some(tab) =>
      if tab.kind == FloatNote {
        float_note_by_id(workspace, tab.note_id)
      } else {
        None
      }
    None => None
  }
}

///|
pub fn float_active_kind(workspace : FloatWorkspace) -> FloatTabKind? {
  match float_active_tab(workspace) {
    Some(tab) => Some(tab.kind)
    None => None
  }
}

///|
pub fn float_terminal_visible(model : Model) -> Bool {
  model.float.open &&
  float_active_kind(model.float) is Some(FloatTerminal)
}

///|
pub fn float_agent_visible(model : Model) -> Bool {
  model.float.open &&
  float_active_kind(model.float) is Some(FloatAgent)
}

///|
fn float_note_updated(
  workspace : FloatWorkspace,
  note_id : String,
  update : (FloatNote) -> FloatNote,
) -> FloatWorkspace {
  let notes : Array[FloatNote] = []
  for note in workspace.notes {
    if note.id == note_id {
      notes.push(update(note))
    } else {
      notes.push(note)
    }
  }
  { ..workspace, notes }
}

///|
fn float_note_tab(
  note : FloatNote,
  index : Int,
) -> FloatTab {
  { id: "tab-" + note.id + "-" + index.to_string(), kind: FloatNote, note_id: note.id }
}

///|
pub fn float_new_note(workspace : FloatWorkspace, lang : Lang) -> FloatWorkspace {
  let sequence = workspace.next_id
  let note_id = "n" + sequence.to_string()
  let file_name = match float_note_file_name(note_id) {
    Some(name) => name
    None => "note-fallback.md"
  }
  let note = {
    id: note_id,
    title: tr(lang, "Note ", "笔记 ") + sequence.to_string(),
    file_name,
    content: "",
    state: FloatNoteSaving,
    revision: 1,
  }
  let tab = {
    id: "tab-" + note_id,
    kind: FloatNote,
    note_id,
  }
  let notes = workspace.notes.copy()
  notes.push(note)
  let tabs = workspace.tabs.copy()
  tabs.push(tab)
  {
    ..workspace,
    tabs,
    notes,
    active_tab: tab.id,
    next_id: sequence + 1,
    menu_open: false,
    message: "",
  }
}

///|
fn float_tab_for_kind(
  workspace : FloatWorkspace,
  kind : FloatTabKind,
) -> FloatTab? {
  for tab in workspace.tabs {
    if tab.kind == kind {
      return Some(tab)
    }
  }
  None
}

///|
pub fn float_new_kind_tab(
  workspace : FloatWorkspace,
  kind : FloatTabKind,
) -> FloatWorkspace {
  match float_tab_for_kind(workspace, kind) {
    Some(tab) => {
      ..workspace,
      active_tab: tab.id,
      menu_open: false,
      message: "",
    }
    None => {
      let tab = {
        id: "tab-" + kind.value(),
        kind,
        note_id: "",
      }
      let tabs = workspace.tabs.copy()
      tabs.push(tab)
      {
        ..workspace,
        tabs,
        active_tab: tab.id,
        menu_open: false,
        message: "",
      }
    }
  }
}

///|
pub fn float_close_tab(
  workspace : FloatWorkspace,
  tab_id : String,
) -> FloatWorkspace {
  let mut removed_index = -1
  let mut index = 0
  for tab in workspace.tabs {
    if tab.id == tab_id {
      removed_index = index
    }
    index = index + 1
  }
  if removed_index < 0 {
    return workspace
  }
  let tabs : Array[FloatTab] = []
  for tab in workspace.tabs {
    if tab.id != tab_id {
      tabs.push(tab)
    }
  }
  let active_tab = if workspace.active_tab != tab_id {
    workspace.active_tab
  } else if tabs.is_empty() {
    ""
  } else if removed_index < tabs.length() {
    tabs[removed_index].id
  } else {
    tabs[tabs.length() - 1].id
  }
  { ..workspace, tabs, active_tab }
}

///|
fn float_json_array(
  object : Map[String, @json.Json],
  key : String,
) -> Array[@json.Json] {
  match object.get(key) {
    Some(@json.Json::Array(items)) => items
    _ => []
  }
}

///|
fn float_json_double(
  object : Map[String, @json.Json],
  key : String,
  fallback : Double,
) -> Double {
  match object.get(key) {
    Some(@json.Json::Number(value, ..)) => value
    _ => fallback
  }
}

///|
fn float_tab_json(tab : FloatTab) -> @json.Json {
  @contracts.json_object([
    ("id", @contracts.json_string(tab.id)),
    ("kind", @contracts.json_string(tab.kind.value())),
    ("note_id", @contracts.json_string(tab.note_id)),
  ])
}

///|
fn float_note_meta_json(note : FloatNote) -> @json.Json {
  @contracts.json_object([
    ("id", @contracts.json_string(note.id)),
    ("title", @contracts.json_string(note.title)),
    ("file", @contracts.json_string(note.file_name)),
  ])
}

///|
pub fn encode_float_workspace(workspace : FloatWorkspace) -> String {
  let note_items : Array[@json.Json] = []
  for note in workspace.notes {
    note_items.push(float_note_meta_json(note))
  }
  let tab_items : Array[@json.Json] = []
  for tab in workspace.tabs {
    tab_items.push(float_tab_json(tab))
  }
  @contracts.json_object([
    ("schema_version", @contracts.json_int(FLOAT_WORKSPACE_SCHEMA_VERSION)),
    ("x", @json.Json::number(workspace.x)),
    ("y", @json.Json::number(workspace.y)),
    ("width", @json.Json::number(workspace.width)),
    ("height", @json.Json::number(workspace.height)),
    ("active_tab", @contracts.json_string(workspace.active_tab)),
    ("next_id", @contracts.json_int(workspace.next_id)),
    ("menu_open", @contracts.json_bool(false)),
    ("tabs", @contracts.json_array(tab_items)),
    ("notes", @contracts.json_array(note_items)),
  ]).stringify()
}

///|
pub fn decode_float_workspace(
  text : String,
) -> FloatWorkspaceRestore? {
  let json = @json.parse(text) catch { _ => return None }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let version = match @contracts.int_field(object, "schema_version") {
    Some(value) => value
    None => return None
  }
  if version != FLOAT_WORKSPACE_SCHEMA_VERSION {
    return None
  }
  let note_meta : Array[FloatNoteMeta] = []
  for item in float_json_array(object, "notes") {
    match @contracts.as_object(item) {
      Some(record) => {
        let id = @contracts.string_field_or(record, "id", "")
        let title = @contracts.string_field_or(record, "title", "")
        let file_name = @contracts.string_field_or(record, "file", "")
        if id != "" && file_name != "" {
          note_meta.push({ id, title, file_name, })
        }
      }
      None => ()
    }
  }
  let tabs : Array[FloatTab] = []
  let has_tabs_field = object.get("tabs") is Some(@json.Json::Array(_))
  if has_tabs_field {
    for item in float_json_array(object, "tabs") {
      match @contracts.as_object(item) {
        Some(record) => {
          let id = @contracts.string_field_or(record, "id", "")
          let kind = match float_tab_kind_from_value(
            @contracts.string_field_or(record, "kind", ""),
          ) {
            Some(value) => value
            None => continue
          }
          let note_id = @contracts.string_field_or(record, "note_id", "")
          if id != "" {
            if kind == FloatNote {
              if note_id != "" {
                tabs.push({ id, kind, note_id, })
              }
            } else {
              tabs.push({ id, kind, note_id: "", })
            }
          }
        }
        None => ()
      }
    }
  } else {
    let mut index = 0
    for meta in note_meta {
      tabs.push(float_note_tab({
        id: meta.id,
        title: meta.title,
        file_name: meta.file_name,
        content: "",
        state: FloatNoteSaved,
        revision: 0,
      }, index))
      index = index + 1
    }
  }
  let notes : Array[FloatNote] = []
  for meta in note_meta {
    notes.push({
      id: meta.id,
      title: meta.title,
      file_name: meta.file_name,
      content: "",
      state: FloatNoteSaved,
      revision: 0,
    })
  }
  let active_tab = match @contracts.string_field(object, "active_tab") {
    Some(value) => value
    None => ""
  }
  let next_id = @contracts.int_field_or(object, "next_id", 2).max(2)
  Some({
    has_state: true,
    x: float_json_double(object, "x", 248.0),
    y: float_json_double(object, "y", 64.0),
    width: float_json_double(object, "width", 904.0),
    height: float_json_double(object, "height", 620.0),
    active_tab,
    tabs,
    notes,
    next_id,
    message: "",
  })
}

///|
fn float_restore_with_notes(
  restore : FloatWorkspaceRestore,
  notes : Array[FloatNote],
) -> FloatWorkspaceRestore {
  let valid : Map[String, Bool] = Map([])
  for note in notes {
    valid.set(note.id, true)
  }
  let tabs : Array[FloatTab] = []
  for tab in restore.tabs {
    if tab.kind == FloatNote {
      if valid.get(tab.note_id) is Some(true) {
        tabs.push(tab)
      }
    } else {
      tabs.push(tab)
    }
  }
  let mut active_tab = restore.active_tab
  let mut active_found = false
  for tab in tabs {
    if tab.id == active_tab {
      active_found = true
    }
  }
  if !active_found {
    active_tab = if tabs.is_empty() { "" } else { tabs[0].id }
  }
  { ..restore, notes, tabs, active_tab }
}

///|
pub async fn read_float_restore_in(
  config_dir : String,
) -> FloatWorkspaceRestore {
  let state_path = float_state_path_in(config_dir)
  let notes_dir = float_notes_dir_in(config_dir)
  let state_exists = @fs.exists(state_path) catch { _ => false }
  let mut decoded : FloatWorkspaceRestore? = None
  let mut state_error = ""
  if state_exists {
    let text = @fs.read_file(state_path).text() catch {
      error => {
        state_error = "cannot read " + state_path + ": " + error.to_string()
        ""
      }
    }
    if state_error == "" {
      match decode_float_workspace(text) {
        Some(value) => decoded = Some(value)
        None =>
          state_error =
            "ignoring " + state_path + ": expected a floating workspace index"
      }
    }
  }
  match decoded {
    Some(restore) => {
      let notes : Array[FloatNote] = []
      for meta in restore.notes {
        match float_note_path_in(notes_dir, meta.file_name) {
          Some(path) => {
            let exists = @fs.exists(path) catch { _ => false }
            if exists {
              let content = @fs.read_file(path).text() catch { _ => "" }
              if float_note_title_problem(meta.title) is None {
                notes.push({
                  id: meta.id,
                  title: meta.title,
                  file_name: meta.file_name,
                  content,
                  state: FloatNoteSaved,
                  revision: 0,
                })
              }
            }
          }
          None => ()
        }
      }
      {
        ..float_restore_with_notes(restore, notes),
        message: restore.message,
      }
    }
    None => {
      let names = @fs.readdir(notes_dir, sort=true) catch { _ => [] }
      let notes : Array[FloatNote] = []
      let tabs : Array[FloatTab] = []
      let mut index = 0
      let mut next_id = 2
      for name in names {
        if name.has_suffix(".md") {
          match float_note_path_in(notes_dir, name) {
            Some(path) => {
              let content = @fs.read_file(path).text() catch { _ => "" }
              let stem = name[:name.length() - 3].to_owned()
              if stem.has_prefix("note-n") {
                let sequence = @string.parse_int(
                  stem.substring(start=6),
                ) catch {
                  _ => 0
                }
                if sequence >= next_id {
                  next_id = sequence + 1
                }
              }
              let note = {
                id: stem,
                title: stem,
                file_name: name,
                content,
                state: FloatNoteSaved,
                revision: 0,
              }
              tabs.push(float_note_tab(note, index))
              notes.push(note)
              index = index + 1
            }
            None => ()
          }
        }
      }
      {
        has_state: state_exists || !notes.is_empty(),
        x: 248.0,
        y: 64.0,
        width: 904.0,
        height: 620.0,
        active_tab: if tabs.is_empty() { "" } else { tabs[0].id },
        tabs,
        notes,
        next_id,
        message: state_error,
      }
    }
  }
}

///|
async fn float_atomic_write(
  path : String,
  text : String,
) -> Result[Unit, String] {
  let directory = match path.rev_find("/") {
    Some(index) => path[:index].to_owned()
    None => "."
  }
  @fs.mkdir(directory, permission=0o700, recursive=true, allow_exist=true) catch {
    error => return Err("cannot create " + directory + ": " + error.to_string())
  }
  let temp_path = path + ".tmp"
  @fs.write_file(
    temp_path,
    text,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  ) catch {
    error => return Err("cannot write " + temp_path + ": " + error.to_string())
  }
  @fs.chmod(temp_path, 0o600) catch {
    error => return Err("cannot secure " + temp_path + ": " + error.to_string())
  }
  @fs.rename(temp_path, path, replace=true) catch {
    error => return Err("cannot publish " + path + ": " + error.to_string())
  }
  Ok(())
}

///|
pub async fn write_float_note_in(
  config_dir : String,
  file_name : String,
  content : String,
) -> Result[Unit, String] {
  let notes_dir = float_notes_dir_in(config_dir)
  let path = match float_note_path_in(notes_dir, file_name) {
    Some(value) => value
    None => return Err("unsafe note file name: " + file_name)
  }
  float_atomic_write(path, content)
}

///|
pub async fn write_float_state_in(
  config_dir : String,
  text : String,
) -> Result[Unit, String] {
  float_atomic_write(float_state_path_in(config_dir), text)
}

///|
let float_persist_queue : @aqueue.Queue[FloatPersistRequest] = @aqueue.Queue(
  kind=Unbounded,
)

///|
let float_dispatch_cell : Ref[((Msg) -> Unit)?] = Ref(None)

///|
fn float_enqueue(request : FloatPersistRequest) -> Unit {
  ignore(float_persist_queue.try_put(request) catch { _ => false })
}

///|
pub fn enqueue_float_restore() -> Unit {
  float_enqueue(FloatRestoreRequest)
}

///|
pub fn enqueue_float_note(write : FloatNoteWrite) -> Unit {
  float_enqueue(FloatNoteRequest(write))
}

///|
pub fn enqueue_float_state(text : String) -> Unit {
  float_enqueue(FloatStateRequest(text))
}

///|
pub fn float_capture_dispatch(dispatch : (Msg) -> Unit) -> Unit {
  float_dispatch_cell.val = Some(dispatch)
  enqueue_float_restore()
}

///|
fn float_dispatch(msg : Msg) -> Unit {
  match float_dispatch_cell.val {
    Some(dispatch) => dispatch(msg)
    None => ()
  }
}

///|
async fn float_restore_and_dispatch(config_dir : String) -> Unit {
  let restore = read_float_restore_in(config_dir)
  float_dispatch(FloatWorkspaceRestored(restore))
}

///|
async fn float_consume_restore(config_dir : String) -> Unit {
  float_restore_and_dispatch(config_dir)
}

///|
/// Background worker for local note persistence. A short debounce coalesces
/// keystrokes; one file per note is written atomically, then the workspace
/// index is rewritten so tabs and geometry survive a process restart.
pub async fn float_notes_loop(config_dir : String) -> Unit {
  for ;; {
    let first = float_persist_queue.get() catch { _ => return }
    match first {
      FloatRestoreRequest => float_consume_restore(config_dir)
      FloatNoteRequest(_) | FloatStateRequest(_) => {
        @async.sleep(FLOAT_NOTE_DEBOUNCE_MS)
        let notes : Map[String, FloatNoteWrite] = Map([])
        let mut state_json = ""
        let mut restore_pending = false
        let pending : Array[FloatPersistRequest] = [first]
        while true {
          let next = float_persist_queue.try_get() catch { _ => None }
          match next {
            Some(request) => pending.push(request)
            None => break
          }
        }
        for request in pending {
          match request {
            FloatNoteRequest(write) => {
              notes.set(write.note_id, write)
              state_json = write.state_json
            }
            FloatStateRequest(text) => state_json = text
            FloatRestoreRequest => restore_pending = true
          }
        }
        for _note_id, write in notes {
          let result = write_float_note_in(
            config_dir,
            write.file_name,
            write.content,
          )
          let (ok, message) = match result {
            Ok(_) => (true, "")
            Err(error) => (false, error)
          }
          float_dispatch(FloatNoteStored(
            write.note_id,
            write.revision,
            ok,
            message,
          ))
        }
        if state_json != "" {
          ignore(write_float_state_in(config_dir, state_json))
        }
        if restore_pending {
          float_consume_restore(config_dir)
        }
      }
    }
  }
}

///|
pub fn float_note_write_for(
  workspace : FloatWorkspace,
  note_id : String,
) -> FloatNoteWrite? {
  match float_note_by_id(workspace, note_id) {
    Some(note) =>
      Some({
        note_id: note.id,
        file_name: note.file_name,
        content: note.content,
        revision: note.revision,
        state_json: encode_float_workspace(workspace),
      })
    None => None
  }
}

///|
pub fn float_persist_requests(
  workspace : FloatWorkspace,
  msg : Msg,
) -> Array[FloatPersistRequest] {
  let requests : Array[FloatPersistRequest] = []
  match msg {
    FloatNoteContentDraft(_) | FloatNoteTitleDraft(_) =>
      match float_active_note(workspace) {
        Some(note) =>
          match float_note_write_for(workspace, note.id) {
            Some(write) => requests.push(FloatNoteRequest(write))
            None => ()
          }
        None => ()
      }
    FloatNewNote =>
      match float_active_note(workspace) {
        Some(note) =>
          match float_note_write_for(workspace, note.id) {
            Some(write) => requests.push(FloatNoteRequest(write))
            None => ()
          }
        None => requests.push(FloatStateRequest(encode_float_workspace(workspace)))
      }
    ToggleFloatWorkspace =>
      if workspace.open {
        requests.push(FloatStateRequest(encode_float_workspace(workspace)))
        match float_active_note(workspace) {
          Some(note) =>
            match float_note_write_for(workspace, note.id) {
              Some(write) => requests.push(FloatNoteRequest(write))
              None => ()
            }
          None => ()
        }
      } else {
        requests.push(FloatStateRequest(encode_float_workspace(workspace)))
      }
    CloseFloatWorkspace | FloatCloseTab(_) | FloatSelectTab(_) |
    FloatNewAgent | FloatNewTerminal | FloatMenu(_) =>
      requests.push(FloatStateRequest(encode_float_workspace(workspace)))
    FloatHeaderDrag(phase, _, _) | FloatResizeDrag(phase, _, _) =>
      match phase {
        @core.DragGesturePhase::Ended | @core.DragGesturePhase::Cancelled =>
          requests.push(FloatStateRequest(encode_float_workspace(workspace)))
        _ => ()
      }
    _ => ()
  }
  requests
}
