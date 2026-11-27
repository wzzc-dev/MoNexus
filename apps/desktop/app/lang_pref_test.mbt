///|
test "language preference encodes and decodes both values" {
  let english = encode_lang_pref(English)
  assert_true(english.contains("\"schema_version\":1"))
  assert_true(english.contains("\"language\":\"en\""))
  let chinese = encode_lang_pref(Chinese)
  assert_true(chinese.contains("\"language\":\"zh\""))
  assert_true(decode_lang_pref(english) is Some(English))
  assert_true(decode_lang_pref(chinese) is Some(Chinese))
  // Hand-written values and common tags are accepted case-insensitively.
  assert_true(
    decode_lang_pref("{\"schema_version\":1,\"language\":\"ZH-CN\"}") is
    Some(Chinese),
  )
}

///|
test "language preference decoding rejects corrupt and unknown payloads" {
  assert_true(decode_lang_pref("") is None)
  assert_true(decode_lang_pref("{") is None)
  assert_true(decode_lang_pref("[]") is None)
  assert_true(decode_lang_pref("{\"language\":\"zh\"}") is None)
  assert_true(decode_lang_pref("{\"schema_version\":1}") is None)
  assert_true(
    decode_lang_pref("{\"schema_version\":1,\"language\":\"fr\"}") is None,
  )
  assert_true(
    decode_lang_pref("{\"schema_version\":1,\"language\":42}") is None,
  )
  assert_true(
    decode_lang_pref("{\"schema_version\":2,\"language\":\"zh\"}") is None,
  )
}

///|
test "language tags accept English and Chinese aliases" {
  assert_true(lang_from_value("EN") is Some(English))
  assert_true(lang_from_value("en-US") is Some(English))
  assert_true(lang_from_value("english") is Some(English))
  assert_true(lang_from_value("zh") is Some(Chinese))
  assert_true(lang_from_value("zh-hans") is Some(Chinese))
  assert_true(lang_from_value("cn") is Some(Chinese))
  assert_true(lang_from_value("chinese") is Some(Chinese))
  assert_true(lang_from_value("fr") is None)
}

///|
test "startup language precedence is saved, then env, then English" {
  let saved = resolve_startup_language(SavedLanguageChoice(Chinese), Some("en"))
  assert_true(saved.language == Chinese)
  assert_eq(saved.source, "saved")
  assert_eq(saved.note, "")
  let env = resolve_startup_language(NoLanguageChoice, Some("zh-CN"))
  assert_true(env.language == Chinese)
  assert_eq(env.source, "environment")
  assert_eq(env.note, "")
  let default = resolve_startup_language(NoLanguageChoice, None)
  assert_true(default.language == English)
  assert_eq(default.source, "default")
  assert_eq(default.note, "")
  let illegal = resolve_startup_language(NoLanguageChoice, Some("fr"))
  assert_true(illegal.language == English)
  assert_eq(illegal.source, "default")
  assert_true(illegal.note.contains("MONEXUS_LANG=fr"))
}

///|
test "SetLanguage flips labels and save results update the diagnostic" {
  let model = update(Model::new(), SetLanguage(Chinese))
  assert_true(model.lang == Chinese)
  assert_eq(model.page.label_in(model.lang), "对话")
  let failed = update(
    model,
    LanguageStored(LanguageSaveFailed("permission denied")),
  )
  assert_true(failed.lang_note.contains("permission denied"))
  assert_true(failed.lang_note.contains("语言偏好未保存"))
  let recovered = update(failed, LanguageStored(LanguageSaveOk))
  assert_eq(recovered.lang_note, "")
  let english = update(recovered, SetLanguage(English))
  assert_eq(english.page.label_in(english.lang), "Chats")
}

///|
test "the Settings language control switches the whole shell" {
  let harness = @test_support.WidgetHarness::from_program(
    program=program(),
    width=1280.0,
    height=800.0,
  )
  harness.tap_text("Settings")
  assert_true(harness.has_text("Language"))
  harness.tap_text("中文")
  assert_true(harness.has_text("设置"))
  assert_true(harness.has_text("连接"))
  assert_true(harness.has_text("外观"))
  assert_true(harness.has_text("语言"))
  assert_true(harness.has_text("令牌：未知（主机未连接）"))
  harness.tap_text("新对话")
  assert_true(harness.has_text("创建对话"))
  assert_true(harness.has_text("对话标题"))
  harness.tap_text("设置")
  harness.tap_text("English")
  assert_true(harness.has_text("Connection"))
  harness.tap_text("New Chat")
  assert_true(harness.has_text("Create Chat"))
  assert_true(harness.has_text("Chat title"))
}

///|
async test "language choice round-trips atomically with mode 0600" {
  let dir = @fs.tmpdir(prefix="monexus-lang-pref-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  assert_true(read_language_choice_in(config) is NoLanguageChoice)
  assert_true(write_language_choice_in(config, Chinese) is Ok(_))
  assert_true(read_language_choice_in(config) is SavedLanguageChoice(Chinese))
  let path = lang_pref_path_in(config)
  assert_true(@fs.exists(path))
  assert_true(!(@fs.exists(path + ".tmp")))
  assert_eq(theme_test_mode(path), "600")
  assert_true(write_language_choice_in(config, English) is Ok(_))
  assert_true(read_language_choice_in(config) is SavedLanguageChoice(English))
  assert_eq(theme_test_mode(path), "600")
}

///|
async test "a corrupt language file is ignored, reported and left intact" {
  let dir = @fs.tmpdir(prefix="monexus-lang-corrupt-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  @fs.mkdir(config, permission=0o700, recursive=true, allow_exist=true)
  let path = lang_pref_path_in(config)
  let corrupt = "{\"schema_version\":1,\"language\":\"fr\"}"
  @fs.write_file(
    path,
    corrupt,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o600,
  )
  let choice = read_language_choice_in(config)
  match choice {
    InvalidLanguageChoice(message) => assert_true(message.contains(path))
    _ => assert_true(false)
  }
  let startup = startup_language_in(config, None)
  assert_true(startup.language == English)
  assert_eq(startup.source, "default")
  assert_true(startup.note.contains("language.json"))
  assert_eq(@fs.read_file(path).text(), corrupt)
}

///|
async test "a saved Chinese choice seeds a fresh model" {
  let dir = @fs.tmpdir(prefix="monexus-lang-startup-")
  defer @fs.rmdir(dir, recursive=true)
  let config = dir + "/monexus"
  assert_true(write_language_choice_in(config, Chinese) is Ok(_))
  let startup = startup_language_in(config, Some("en"))
  assert_true(startup.language == Chinese)
  assert_eq(startup.source, "saved")
  let model = Model::new_with_preferences(
    { mode: Dark, source: "default", note: "" },
    startup,
  )
  assert_true(model.lang == Chinese)
  assert_eq(model.lang_note, "")
  assert_eq(model.page.label_in(model.lang), "对话")
}
