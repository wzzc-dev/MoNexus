///|
/// Desktop appearance preference (V0.1 theme persistence).
///
/// The Settings page flips Light/Dark immediately. An explicit choice is also
/// stored as one small JSON file under the user's config directory — never in
/// the workspace, the host event log or an RPC endpoint:
///
/// - `$MONEXUS_CONFIG_DIR/theme.json` when that variable is set;
/// - else `$XDG_CONFIG_HOME/monexus/theme.json`;
/// - else `$HOME/.config/monexus/theme.json`;
/// - else `.config/monexus/theme.json` relative to the current directory.
///
/// The file is written atomically (temporary file in the same directory, then
/// `rename(2)`) with mode 0600, mirroring `host.json`. It holds no secrets.
///
/// Startup precedence, highest first:
///
/// 1. a valid saved choice;
/// 2. a legal `MONEXUS_THEME=light|dark`;
/// 3. dark, the product default.
///
/// A missing preference file is silent. An unreadable, corrupt or
/// unknown-valued file is ignored (it never seeds the palette), falls through
/// to the next rule, and produces a readable diagnostic for the Settings page;
/// it is never rewritten on read.
pub const THEME_PREF_SCHEMA_VERSION : Int = 1

///|
pub const THEME_PREF_FILE : String = "theme.json"

///|
/// Result of reading the saved appearance choice. `InvalidThemeChoice` carries
/// a diagnostic and is never treated as a choice.
pub(all) enum ThemeChoice {
  NoThemeChoice
  SavedThemeChoice(ThemeMode)
  InvalidThemeChoice(String)
}

///|
/// Outcome reported by the preference worker after a Settings toggle.
pub(all) enum ThemeSaveStatus {
  ThemeSaveOk
  ThemeSaveFailed(String)
}

///|
/// Resolved startup appearance plus where it came from. `source` is one of
/// `"saved"`, `"environment"` or `"default"`; `note` is empty unless something
/// was ignored and needs to be shown to the user.
pub(all) struct StartupTheme {
  mode : ThemeMode
  source : String
  note : String
}

///|
/// Pure config-directory resolution so precedence is testable without
/// touching the process environment.
pub fn theme_config_dir_from(
  read_env : (String) -> String?,
) -> String {
  match read_env("MONEXUS_CONFIG_DIR") {
    Some(value) if value != "" => return value
    _ => ()
  }
  match read_env("XDG_CONFIG_HOME") {
    Some(value) if value != "" => return value + "/monexus"
    _ => ()
  }
  match read_env("HOME") {
    Some(value) if value != "" => value + "/.config/monexus"
    _ => ".config/monexus"
  }
}

///|
pub fn theme_config_dir() -> String {
  theme_config_dir_from(@env.get_env_var)
}

///|
pub fn theme_pref_path_in(config_dir : String) -> String {
  config_dir + "/" + THEME_PREF_FILE
}

///|
pub fn theme_pref_path() -> String {
  theme_pref_path_in(theme_config_dir())
}

///|
/// One-line JSON with a schema version, matching the repo's discovery-file
/// convention.
pub fn encode_theme_pref(mode : ThemeMode) -> String {
  @contracts.json_object([
    ("schema_version", @contracts.json_int(THEME_PREF_SCHEMA_VERSION)),
    ("theme", @contracts.json_string(mode.pref_value())),
  ]).stringify()
}

///|
/// Decode a preference payload. `None` covers malformed JSON, a missing or
/// unknown schema version, a missing `theme` field and an unknown theme value,
/// so every corrupt case takes the same safe fallback path.
pub fn decode_theme_pref(text : String) -> ThemeMode? {
  let json = @json.parse(text) catch { _ => return None }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let version = match @contracts.int_field(object, "schema_version") {
    Some(value) => value
    None => return None
  }
  if version != THEME_PREF_SCHEMA_VERSION {
    return None
  }
  match @contracts.string_field(object, "theme") {
    Some(value) => theme_mode_from_value(value)
    None => None
  }
}

///|
/// Read the saved choice from an explicit directory. Missing is quiet;
/// unreadable or corrupt content returns a diagnostic without writing
/// anything back.
pub async fn read_theme_choice_in(config_dir : String) -> ThemeChoice {
  let path = theme_pref_path_in(config_dir)
  let exists = @fs.exists(path) catch {
    error => return InvalidThemeChoice("cannot inspect " + path + ": " + error.to_string())
  }
  if !exists {
    return NoThemeChoice
  }
  let text = @fs.read_file(path).text() catch {
    error => return InvalidThemeChoice("cannot read " + path + ": " + error.to_string())
  }
  match decode_theme_pref(text) {
    Some(mode) => SavedThemeChoice(mode)
    None =>
      InvalidThemeChoice(
        "ignoring " + path +
        ": expected {\"schema_version\":1,\"theme\":\"light\"|\"dark\"}",
      )
  }
}

///|
pub async fn read_theme_choice() -> ThemeChoice {
  read_theme_choice_in(theme_config_dir())
}

///|
/// Persist one explicit choice atomically with mode 0600. The temporary file
/// lives beside the target so `rename` stays on one filesystem; a crash
/// leaves at most a stray `.tmp`, never a half-written preference.
pub async fn write_theme_choice_in(
  config_dir : String,
  mode : ThemeMode,
) -> Result[Unit, String] {
  @fs.mkdir(config_dir, permission=0o700, recursive=true, allow_exist=true) catch {
    error => return Err("cannot create " + config_dir + ": " + error.to_string())
  }
  let path = theme_pref_path_in(config_dir)
  let temp_path = path + ".tmp"
  let text = encode_theme_pref(mode)
  @fs.write_file(
    temp_path,
    text,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  ) catch {
    error => return Err("cannot write " + temp_path + ": " + error.to_string())
  }
  // A pre-existing temp file could carry a wider mode; force 0600 before the
  // rename publishes it.
  @fs.chmod(temp_path, 0o600) catch {
    error => return Err("cannot secure " + temp_path + ": " + error.to_string())
  }
  @fs.rename(temp_path, path, replace=true) catch {
    error => return Err("cannot publish " + path + ": " + error.to_string())
  }
  Ok(())
}

///|
pub async fn write_theme_choice(mode : ThemeMode) -> Result[Unit, String] {
  write_theme_choice_in(theme_config_dir(), mode)
}

///|
fn join_theme_notes(first : String, second : String) -> String {
  if first == "" {
    second
  } else if second == "" {
    first
  } else {
    first + "; " + second
  }
}

///|
fn resolve_env_theme(env_value : String?) -> StartupTheme {
  match env_value {
    Some(value) =>
      match theme_mode_from_value(value) {
        Some(mode) => { mode, source: "environment", note: "" }
        None => {
          mode: Dark,
          source: "default",
          note: "ignoring MONEXUS_THEME=" + value + ": expected light or dark",
        }
      }
    None => { mode: Dark, source: "default", note: "" }
  }
}

///|
/// Pure startup precedence: saved choice, then `MONEXUS_THEME`, then dark.
pub fn resolve_startup_theme(
  choice : ThemeChoice,
  env_value : String?,
) -> StartupTheme {
  match choice {
    SavedThemeChoice(mode) => { mode, source: "saved", note: "" }
    NoThemeChoice => resolve_env_theme(env_value)
    InvalidThemeChoice(message) => {
      let fallback = resolve_env_theme(env_value)
      {
        mode: fallback.mode,
        source: fallback.source,
        note: join_theme_notes(message, fallback.note),
      }
    }
  }
}

///|
/// Environment-only resolution, used for tests and screenshot scenes that do
/// not read the preference file. The desktop entry point uses
/// `startup_theme()` so a saved choice is honoured.
pub fn startup_theme_from_env() -> StartupTheme {
  resolve_startup_theme(NoThemeChoice, @env.get_env_var("MONEXUS_THEME"))
}

///|
pub async fn startup_theme_in(
  config_dir : String,
  env_value : String?,
) -> StartupTheme {
  resolve_startup_theme(read_theme_choice_in(config_dir), env_value)
}

///|
/// Resolve the appearance for a fresh desktop launch: the saved choice wins,
/// otherwise `MONEXUS_THEME`, otherwise dark.
pub async fn startup_theme() -> StartupTheme {
  startup_theme_in(theme_config_dir(), @env.get_env_var("MONEXUS_THEME"))
}

///|
/// Writes requested by the Settings page. A queue + worker keeps the update
/// loop pure and file I/O on the background task, following the
/// machine-command pattern.
let theme_choice_queue : @aqueue.Queue[ThemeMode] = @aqueue.Queue(
  kind=Unbounded,
)

///|
pub fn enqueue_theme_choice(mode : ThemeMode) -> Unit {
  ignore(theme_choice_queue.try_put(mode) catch { _ => false })
}

///|
/// Background worker: write each explicit choice and report the result back to
/// the Settings page. Started beside the window; the task group cancels it on
/// exit.
pub async fn theme_choice_loop() -> Unit {
  for ;; {
    let mode = theme_choice_queue.get() catch { _ => return }
    let status = match write_theme_choice(mode) {
      Ok(_) => ThemeSaveOk
      Err(message) => ThemeSaveFailed(message)
    }
    dispatch(ThemeChoiceStored(status))
  }
}
