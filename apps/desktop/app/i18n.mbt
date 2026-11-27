///|
/// Desktop UI language. English is the product default, so an installation
/// that has never chosen a language keeps the existing labels. The Settings
/// page flips the value at runtime and stores the explicit choice through
/// `lang_pref.mbt`.
#derive(Eq)
pub(all) enum Lang {
  English
  Chinese
}

///|
/// Autonym shown on the Settings segmented control. It deliberately does not
/// translate: " English" and "中文" are the conventional language names in
/// their own scripts.
pub fn Lang::label(self : Lang) -> String {
  match self {
    English => "English"
    Chinese => "中文"
  }
}

///|
/// Stable lowercase form used by `language.json` and `MONEXUS_LANG`.
pub fn Lang::pref_value(self : Lang) -> String {
  match self {
    English => "en"
    Chinese => "zh"
  }
}

///|
/// Parse a language tag. Common English and Chinese spellings are accepted
/// case-insensitively; anything else returns `None` so startup falls back
/// deterministically.
pub fn lang_from_value(value : String) -> Lang? {
  match value.to_lower() {
    "en" | "en-us" | "en-gb" | "english" => Some(English)
    "zh" | "zh-cn" | "zh-hans" | "zh-sg" | "chinese" | "cn" =>
      Some(Chinese)
    _ => None
  }
}

///|
/// Pick one of two strings for the active language. Callers keep the English
/// and Chinese forms together, which makes missing translations obvious at the
/// call site and keeps technical identifiers (ids, commands, host messages)
/// unchanged.
pub fn tr(lang : Lang, english : String, chinese : String) -> String {
  match lang {
    English => english
    Chinese => chinese
  }
}
