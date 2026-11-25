///|
/// One bounded stream capture. `bytes`/`lines` count everything the child
/// produced; `kept_bytes`/`kept_lines` count what is stored in `text`.
struct Capture {
  text : String
  bytes : Int64
  lines : Int64
  kept_bytes : Int64
  kept_lines : Int64
  truncated : Bool
}

///|
fn empty_capture() -> Capture {
  {
    text: "",
    bytes: 0L,
    lines: 0L,
    kept_bytes: 0L,
    kept_lines: 0L,
    truncated: false,
  }
}

///|
fn utf8_char_bytes(ch : Char) -> Int {
  let code = ch.to_int()
  if code < 0x80 {
    1
  } else if code < 0x800 {
    2
  } else if code < 0x10000 {
    3
  } else {
    4
  }
}

///|
/// Read a child stream to EOF while keeping at most `max_bytes` bytes and
/// `max_lines` lines. Everything past the bound is counted and discarded, so
/// the pipe keeps draining and the child never blocks on a full buffer.
async fn capture_stream(
  reader : @process.ReadFromProcess,
  max_bytes : Int,
  max_lines : Int,
) -> Capture {
  let mut text = ""
  let mut bytes = 0L
  let mut lines = 0L
  let mut kept_bytes = 0L
  let mut kept_lines = 0L
  let mut truncated = false
  let mut any_seen = false
  let mut seen_ends_newline = false
  let mut kept_ends_newline = false
  defer reader.close()
  for ;; {
    let chunk = reader.read_some() catch { _ => break }
    match chunk {
      Some(data) => {
        bytes = bytes + data.length().to_int64()
        let decoded = @utf8.decode_lossy(data[:], ignore_bom=false)
        for ch in decoded {
          any_seen = true
          let is_newline = ch == '\n'
          seen_ends_newline = is_newline
          if is_newline {
            lines = lines + 1L
          }
          let width = utf8_char_bytes(ch).to_int64()
          let fits = kept_bytes + width <= max_bytes.to_int64() &&
            kept_lines < max_lines.to_int64()
          if fits {
            text = text + ch.to_string()
            kept_bytes = kept_bytes + width
            kept_ends_newline = is_newline
            if is_newline {
              kept_lines = kept_lines + 1L
            }
          } else {
            truncated = true
            kept_ends_newline = false
          }
        }
      }
      None => break
    }
  }
  if any_seen && !seen_ends_newline {
    lines = lines + 1L
  }
  if kept_bytes > 0L && !kept_ends_newline {
    kept_lines = kept_lines + 1L
  }
  { text, bytes, lines, kept_bytes, kept_lines, truncated, }
}

///|
/// A fixed, minimal environment for git. No HOME, no SSH agent, no caller
/// values: the subprocess cannot inherit a user key or read global config.
/// Repository config inside the workspace still applies, as git requires.
pub fn git_env() -> Map[String, String] {
  let path = match @env.get_env_var("PATH") {
    Some(value) if value != "" => value
    _ => "/usr/bin:/bin"
  }
  let env : Map[String, String] = Map([])
  env["PATH"] = path
  env["LC_ALL"] = "C"
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["GIT_CONFIG_GLOBAL"] = "/dev/null"
  env["GIT_TERMINAL_PROMPT"] = "0"
  env["GIT_PAGER"] = "cat"
  env["PAGER"] = "cat"
  env["GIT_OPTIONAL_LOCKS"] = "0"
  env
}
