///|
fn theme_env_map(entries : Map[String, String]) -> (String) -> String? {
  fn(key) { entries.get(key) }
}

///|
fn restore_env_var(key : String, previous : String?) -> Unit {
  match previous {
    Some(value) => @env.set_env_var(key, value)
    None => @env.unset_env_var(key)
  }
}

///|
/// GNU `stat -c %a` on Linux, BSD `stat -f %Lp` on macOS.
async fn theme_test_mode(path : String) -> String {
  let (code, out, _) = @process.collect_output("stat", ["-c", "%a", path]) catch {
    _ => return ""
  }
  if code == 0 {
    return out.text().trim().to_owned()
  }
  let (fallback_code, fallback_out, _) = @process.collect_output("stat", [
    "-f", "%Lp", path,
  ]) catch {
    _ => return ""
  }
  if fallback_code != 0 {
    return ""
  }
  fallback_out.text().trim().to_owned()
}

///|
test "theme preference encodes both modes" {
  let light = encode_theme_pref(Light)
  assert_true(light.contains("\"schema_version\":1"))
  assert_true(light.contains("\"theme\":\"light\""))
  let dark = encode_theme_pref(Dark)
  assert_true(dark.contains("\"theme\":\"dark\""))
}

///|
test "theme preference decodes legal values" {
  assert_true(decode_theme_pref(encode_theme_pref(Light)) is Some(Light))
  assert_true(decode_theme_pref(encode_theme_pref(Dark)) is Some(Dark))
  // Values written by hand are accepted case-insensitively.
  assert_true(
    decode_theme_pref("{\"schema_version\":1,\"theme\":\"LIGHT\"}") is Some(Light),
  )
}

///|
test "theme preference decoding rejects corrupt and unknown payloads" {
  assert_true(decode_theme_pref("") is None)
  assert_true(decode_theme_pref("{") is None)
  assert_true(decode_theme_pref("[]") is None)
  assert_true(decode_theme_pref("{\"theme\":\"light\"}") is None)
  assert_true(decode_theme_pref("{\"schema_version\":1}") is None)
  assert_true(
    decode_theme_pref("{\"schema_version\":1,\"theme\":\"purple\"}") is None,
  )
  assert_true(
    decode_theme_pref("{\"schema_version\":1,\"theme\":42}") is None,
  )
  // Unknown future schema versions fall back instead of guessing.
  assert_true(
    decode_theme_pref("{\"schema_version\":2,\"theme\":\"light\"}") is None,
  )
}

///|
test "theme config directory follows MONEXUS_CONFIG_DIR, XDG_CONFIG_HOME and HOME" {
  let all = theme_env_map(Map([
    ("MONEXUS_CONFIG_DIR", "/cfg"),
    ("XDG_CONFIG_HOME", "/xdg"),
    ("HOME", "/home/user"),
  ]))
  assert_eq(theme_config_dir_from(all), "/cfg")
  let xdg = theme_env_map(Map([
    ("XDG_CONFIG_HOME", "/xdg"),
    ("HOME", "/home/user"),
  ]))
  assert_eq(theme_config_dir_from(xdg), "/xdg/monexus")
  let home = theme_env_map(Map([("HOME", "/home/user")]))
  assert_eq(theme_config_dir_from(home), "/home/user/.config/monexus")
  let none = theme_env_map(Map([]))
  assert_eq(theme_config_dir_from(none), ".config/monexus")
  // Empty values are treated as unset, like the state-directory discovery.
  let empty = theme_env_map(Map([
    ("MONEXUS_CONFIG_DIR", ""),
    ("XDG_CONFIG_HOME", ""),
    ("HOME", "/home/user"),
  ]))
  assert_eq(theme_config_dir_from(empty), "/home/user/.config/monexus")
}

///|
test "startup precedence is saved, then env, then default" {
  let saved = resolve_startup_theme(SavedThemeChoice(Light), Some("dark"))
  assert_true(saved.mode == Light)
  assert_eq(saved.source, "saved")
  assert_eq(saved.note, "")
  let env = resolve_startup_theme(NoThemeChoice, Some("light"))
  assert_true(env.mode == Light)
  assert_eq(env.source, "environment")
  assert_eq(env.note, "")
  let env_dark = resolve_startup_theme(NoThemeChoice, Some("DARK"))
  assert_true(env_dark.mode == Dark)
  assert_eq(env_dark.source, "environment")
  let default = resolve_startup_theme(NoThemeChoice, None)
  assert_true(default.mode == Light)
  assert_eq(default.source, "default")
  assert_eq(default.note, "")
}

///|
test "an illegal MONEXUS_THEME falls back to light with a diagnostic" {
  let startup = resolve_startup_theme(NoThemeChoice, Some("sepia"))
  assert_true(startup.mode == Light)
  assert_eq(startup.source, "default")
  assert_true(startup.note.contains("MONEXUS_THEME=sepia"))
}

///|
test "an invalid saved choice falls through and reports why" {
  let with_env = resolve_startup_theme(InvalidThemeChoice("bad theme.json"), Some("light"))
  assert_true(with_env.mode == Light)
  assert_eq(with_env.source, "environment")
  assert_true(with_env.note.contains("bad theme.json"))
  let bare = resolve_startup_theme(InvalidThemeChoice("bad theme.json"), None)
  assert_true(bare.mode == Light)
  assert_eq(bare.source, "default")
  assert_true(bare.note.contains("bad theme.json"))
}

///|
test "SetTheme flips the model and save results update the diagnostic" {
  let model = update(Model::new(), SetTheme(Light))
  assert_true(model.theme_mode == Light)
  let failed = update(
    model,
    ThemeChoiceStored(ThemeSaveFailed("permission denied")),
  )
  assert_true(failed.theme_note.contains("permission denied"))
  let recovered = update(failed, ThemeChoiceStored(ThemeSaveOk))
  assert_eq(recovered.theme_note, "")
}

///|
async test "theme choice round-trips atomically with mode 0600" {
  let dir = @fs.tmpdir(prefix="monexus-theme-pref-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  assert_true(read_theme_choice_in(config) is NoThemeChoice)
  assert_true(write_theme_choice_in(config, Light) is Ok(_))
  assert_true(read_theme_choice_in(config) is SavedThemeChoice(Light))
  let path = theme_pref_path_in(config)
  assert_true(@fs.exists(path))
  assert_true(!(@fs.exists(path + ".tmp")))
  assert_eq(theme_test_mode(path), "600")
  // Replacing the choice publishes one complete file, still mode 0600.
  assert_true(write_theme_choice_in(config, Dark) is Ok(_))
  assert_true(read_theme_choice_in(config) is SavedThemeChoice(Dark))
  assert_eq(theme_test_mode(path), "600")
}

///|
async test "a corrupt preference file is ignored, reported and left intact" {
  let dir = @fs.tmpdir(prefix="monexus-theme-corrupt-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  @fs.mkdir(config, permission=0o700, recursive=true, allow_exist=true)
  let path = theme_pref_path_in(config)
  let corrupt = "{\"schema_version\":1,\"theme\":\"purple\"}"
  @fs.write_file(
    path,
    corrupt,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  let choice = read_theme_choice_in(config)
  match choice {
    InvalidThemeChoice(message) => assert_true(message.contains(path))
    _ => assert_true(false)
  }
  let startup = startup_theme_in(config, None)
  assert_true(startup.mode == Light)
  assert_eq(startup.source, "default")
  assert_true(startup.note.contains("theme.json"))
  // Reading never rewrites what the user has on disk.
  assert_eq(@fs.read_file(path).text(), corrupt)
}

///|
async test "a missing preference file is silent and does not create one" {
  let dir = @fs.tmpdir(prefix="monexus-theme-missing-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  let startup = startup_theme_in(config, Some("light"))
  assert_true(startup.mode == Light)
  assert_eq(startup.source, "environment")
  assert_eq(startup.note, "")
  assert_true(!(@fs.exists(theme_pref_path_in(config))))
}

///|
async test "a saved choice seeds a fresh model and is written 0600" {
  let dir = @fs.tmpdir(prefix="monexus-theme-startup-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  assert_true(write_theme_choice_in(config, Light) is Ok(_))
  // MONEXUS_THEME=dark must not override an explicit saved choice.
  let startup = startup_theme_in(config, Some("dark"))
  assert_true(startup.mode == Light)
  assert_eq(startup.source, "saved")
  let model = Model::new_with_startup(startup)
  assert_true(model.theme_mode == Light)
  assert_eq(model.theme_note, "")
  assert_eq(theme_test_mode(theme_pref_path_in(config)), "600")
}

///|
async test "the public preference path honours a temporary XDG config dir" {
  let dir = @fs.tmpdir(prefix="monexus-theme-xdg-")
  defer @fs.rmdir(dir, recursive=true)
  let previous_config = @env.get_env_var("MONEXUS_CONFIG_DIR")
  let previous_xdg = @env.get_env_var("XDG_CONFIG_HOME")
  @env.unset_env_var("MONEXUS_CONFIG_DIR")
  @env.set_env_var("XDG_CONFIG_HOME", dir)
  defer restore_env_var("XDG_CONFIG_HOME", previous_xdg)
  defer restore_env_var("MONEXUS_CONFIG_DIR", previous_config)
  assert_eq(theme_pref_path(), dir + "/monexus/theme.json")
  assert_true(write_theme_choice(Dark) is Ok(_))
  let choice = read_theme_choice()
  let detail = match choice {
    SavedThemeChoice(mode) => "saved " + mode.label()
    NoThemeChoice => "missing at " + theme_pref_path()
    InvalidThemeChoice(message) => "invalid: " + message
  }
  assert_true(choice is SavedThemeChoice(Dark), msg=detail)
  assert_true(@fs.exists(dir + "/monexus/theme.json"))
}

///|
async test "the public preference path honours MONEXUS_CONFIG_DIR" {
  let dir = @fs.tmpdir(prefix="monexus-theme-env-")
  defer @fs.rmdir(dir, recursive=true)
  let previous = @env.get_env_var("MONEXUS_CONFIG_DIR")
  @env.set_env_var("MONEXUS_CONFIG_DIR", dir)
  defer restore_env_var("MONEXUS_CONFIG_DIR", previous)
  assert_eq(theme_pref_path(), dir + "/theme.json")
  assert_true(write_theme_choice(Light) is Ok(_))
  assert_true(read_theme_choice() is SavedThemeChoice(Light))
  let startup = startup_theme()
  assert_true(startup.mode == Light)
  assert_eq(startup.source, "saved")
}
