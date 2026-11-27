///|
/// Desktop language preference (V0.1 Chinese/English switching).
///
/// The Settings page flips the UI language immediately. An explicit choice is
/// stored as one small JSON file beside `theme.json`, under the same config
/// directory rules:
///
/// - `$MONEXUS_CONFIG_DIR/language.json` when that variable is set;
/// - else `$XDG_CONFIG_HOME/monexus/language.json`;
/// - else `$HOME/.config/monexus/language.json`;
/// - else `.config/monexus/language.json` relative to the current directory.
///
/// The file is written atomically (temporary file in the same directory, then
/// `rename(2)`) with mode 0600. It holds no secrets.
///
/// Startup precedence, highest first:
///
/// 1. a valid saved choice;
/// 2. a legal `MONEXUS_LANG=en|zh`;
/// 3. English, the product default.
///
/// A missing preference file is silent. An unreadable, corrupt or
/// unknown-valued file is ignored and reported for the Settings page; it is
/// never rewritten on read.
pub const LANG_PREF_SCHEMA_VERSION : Int = 1

///|
pub const LANG_PREF_FILE : String = "language.json"

///|
/// Result of reading the saved language. `InvalidLanguageChoice` carries a
/// diagnostic and is never treated as a choice.
pub(all) enum LanguageChoice {
  NoLanguageChoice
  SavedLanguageChoice(Lang)
  InvalidLanguageChoice(String)
}

///|
/// Outcome reported by the preference worker after a Settings toggle.
pub(all) enum LanguageSaveStatus {
  LanguageSaveOk
  LanguageSaveFailed(String)
}

///|
/// Resolved startup language plus where it came from. `source` is one of
/// `"saved"`, `"environment"` or `"default"`; `note` is empty unless something
/// was ignored and needs to be shown to the user.
pub(all) struct StartupLanguage {
  language : Lang
  source : String
  note : String
}

///|
/// The language file shares the appearance directory; keep one resolver so
/// both preferences obey the same environment contract.
pub fn lang_pref_path_in(config_dir : String) -> String {
  config_dir + "/" + LANG_PREF_FILE
}

///|
pub fn lang_pref_path() -> String {
  lang_pref_path_in(theme_config_dir())
}

///|
pub fn encode_lang_pref(lang : Lang) -> String {
  @contracts.json_object([
    ("schema_version", @contracts.json_int(LANG_PREF_SCHEMA_VERSION)),
    ("language", @contracts.json_string(lang.pref_value())),
  ]).stringify()
}

///|
/// Decode a preference payload. `None` covers malformed JSON, a missing or
/// unknown schema version, a missing `language` field and an unknown value.
pub fn decode_lang_pref(text : String) -> Lang? {
  let json = @json.parse(text) catch { _ => return None }
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return None
  }
  let version = match @contracts.int_field(object, "schema_version") {
    Some(value) => value
    None => return None
  }
  if version != LANG_PREF_SCHEMA_VERSION {
    return None
  }
  match @contracts.string_field(object, "language") {
    Some(value) => lang_from_value(value)
    None => None
  }
}

///|
/// Read the saved language from an explicit directory. Missing is quiet;
/// unreadable or corrupt content returns a diagnostic without writing
/// anything back.
pub async fn read_language_choice_in(
  config_dir : String,
) -> LanguageChoice {
  let path = lang_pref_path_in(config_dir)
  let exists = @fs.exists(path) catch {
    error =>
      return InvalidLanguageChoice(
        "cannot inspect " + path + ": " + error.to_string(),
      )
  }
  if !exists {
    return NoLanguageChoice
  }
  let text = @fs.read_file(path).text() catch {
    error =>
      return InvalidLanguageChoice(
        "cannot read " + path + ": " + error.to_string(),
      )
  }
  match decode_lang_pref(text) {
    Some(lang) => SavedLanguageChoice(lang)
    None =>
      InvalidLanguageChoice(
        "ignoring " + path +
        ": expected {\"schema_version\":1,\"language\":\"en\"|\"zh\"}",
      )
  }
}

///|
pub async fn read_language_choice() -> LanguageChoice {
  read_language_choice_in(theme_config_dir())
}

///|
/// Persist one explicit choice atomically with mode 0600.
pub async fn write_language_choice_in(
  config_dir : String,
  lang : Lang,
) -> Result[Unit, String] {
  @fs.mkdir(config_dir, permission=0o700, recursive=true, allow_exist=true) catch {
    error => return Err("cannot create " + config_dir + ": " + error.to_string())
  }
  let path = lang_pref_path_in(config_dir)
  let temp_path = path + ".tmp"
  let text = encode_lang_pref(lang)
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
pub async fn write_language_choice(lang : Lang) -> Result[Unit, String] {
  write_language_choice_in(theme_config_dir(), lang)
}

///|
fn join_language_notes(first : String, second : String) -> String {
  if first == "" {
    second
  } else if second == "" {
    first
  } else {
    first + "; " + second
  }
}

///|
fn resolve_env_language(env_value : String?) -> StartupLanguage {
  match env_value {
    Some(value) =>
      match lang_from_value(value) {
        Some(lang) => { language: lang, source: "environment", note: "" }
        None => {
          language: English,
          source: "default",
          note: "ignoring MONEXUS_LANG=" + value + ": expected en or zh",
        }
      }
    None => { language: English, source: "default", note: "" }
  }
}

///|
/// Pure startup precedence: saved choice, then `MONEXUS_LANG`, then English.
pub fn resolve_startup_language(
  choice : LanguageChoice,
  env_value : String?,
) -> StartupLanguage {
  match choice {
    SavedLanguageChoice(lang) => { language: lang, source: "saved", note: "" }
    NoLanguageChoice => resolve_env_language(env_value)
    InvalidLanguageChoice(message) => {
      let fallback = resolve_env_language(env_value)
      {
        language: fallback.language,
        source: fallback.source,
        note: join_language_notes(message, fallback.note),
      }
    }
  }
}

///|
/// Environment-only resolution, used for tests and screenshot scenes that do
/// not read the preference file.
pub fn startup_language_from_env() -> StartupLanguage {
  resolve_startup_language(NoLanguageChoice, @env.get_env_var("MONEXUS_LANG"))
}

///|
pub async fn startup_language_in(
  config_dir : String,
  env_value : String?,
) -> StartupLanguage {
  resolve_startup_language(read_language_choice_in(config_dir), env_value)
}

///|
/// Resolve the UI language for a fresh desktop launch: the saved choice wins,
/// otherwise `MONEXUS_LANG`, otherwise English.
pub async fn startup_language() -> StartupLanguage {
  startup_language_in(theme_config_dir(), @env.get_env_var("MONEXUS_LANG"))
}

///|
/// Writes requested by the Settings page. A queue + worker keeps the update
/// loop pure and file I/O on the background task.
let language_choice_queue : @aqueue.Queue[Lang] = @aqueue.Queue(
  kind=Unbounded,
)

///|
pub fn enqueue_language_choice(lang : Lang) -> Unit {
  ignore(language_choice_queue.try_put(lang) catch { _ => false })
}

///|
/// Background worker: write each explicit choice and report the result back to
/// the Settings page. Started beside the window; the task group cancels it on
/// exit.
pub async fn language_choice_loop() -> Unit {
  for ;; {
    let lang = language_choice_queue.get() catch { _ => return }
    let status = match write_language_choice(lang) {
      Ok(_) => LanguageSaveOk
      Err(message) => LanguageSaveFailed(message)
    }
    dispatch(LanguageStored(status))
  }
}
