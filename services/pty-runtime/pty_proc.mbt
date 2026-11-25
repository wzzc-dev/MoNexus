///|
/// Linux `/proc` inspection used to report residual processes after a
/// session is finalized. Only processes still in the PTY child's process
/// group are attributable to the session; descendants which call
/// `setsid()`/`setpgid()` leave that group and are documented as outside
/// this runtime's cleanup guarantee.

///|
priv struct ProcStat {
  pid : Int
  pgrp : Int
  zombie : Bool
}

///|
fn pty_parse_pid(view : StringView) -> Int? {
  if view.length() == 0 || view.length() > 10 {
    return None
  }
  let mut value = 0
  for index in 0..<view.length() {
    let code = view.at(index).to_int()
    if code < 48 || code > 57 {
      return None
    }
    value = value * 10 + (code - 48)
  }
  Some(value)
}

///|
fn pty_parse_stat(pid : Int, text : String) -> ProcStat? {
  let close = match text.rev_find(")") {
    Some(index) => index
    None => return None
  }
  let rest = text.substring(start=close + 2)
  let tokens : Array[StringView] = []
  for token in rest.split(" ") {
    if token.length() > 0 {
      tokens.push(token)
    }
  }
  if tokens.length() < 3 {
    return None
  }
  let state = tokens[0].to_string()
  let pgrp = match pty_parse_pid(tokens[2]) {
    Some(value) => value
    None => return None
  }
  Some({ pid, pgrp, zombie: state == "Z" || state == "X", })
}

///|
async fn pty_proc_list() -> Array[ProcStat] {
  let entries = @fs.readdir("/proc", include_hidden=true) catch {
    _ => return []
  }
  let result : Array[ProcStat] = []
  for entry in entries {
    let pid = match pty_parse_pid(entry[:]) {
      Some(value) => value
      None => continue
    }
    let data = @fs.read_file("/proc/" + entry + "/stat") catch {
      _ => continue
    }
    let text = @utf8.decode_lossy(data.binary()[:])
    match pty_parse_stat(pid, text) {
      Some(info) => result.push(info)
      None => ()
    }
  }
  result
}

///|
fn pty_live_group_members(stats : Array[ProcStat], pgid : Int) -> Array[Int] {
  let pids : Array[Int] = []
  for info in stats {
    if info.pgrp == pgid && !info.zombie {
      pids.push(info.pid)
    }
  }
  pids.sort_by(fn(a, b) { a - b })
  pids
}

///|
async fn pty_scan_group(pgid : Int) -> Array[Int] {
  if pgid <= 1 {
    return []
  }
  pty_live_group_members(pty_proc_list(), pgid)
}

///|
extern "c" fn pty_kill_group_raw(
  pgid : Int32,
  signal_number : Int32,
) -> Int32 = "monexus_pty_kill_group"

///|
fn pty_kill_group(pgid : Int, signal_number : Int) -> Unit {
  if pgid <= 1 {
    return
  }
  let _ = pty_kill_group_raw(pgid, signal_number)
}
