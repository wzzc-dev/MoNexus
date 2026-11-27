///|
/// Process-table inspection used to report residual processes after a
/// session is finalized. Only processes still in the PTY child's process
/// group are attributable to the session; descendants which call
/// `setsid()`/`setpgid()` leave that group and are documented as outside
/// this runtime's cleanup guarantee.
///
/// `ps -A -o pid=,pgid=,stat=` is used instead of Linux `/proc`: macOS has
/// no `/proc`, and both BSD and GNU `ps` understand this fixed form.

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
async fn pty_proc_list() -> Array[ProcStat] {
  let ps = if (@fs.exists("/bin/ps") catch { _ => false }) {
    "/bin/ps"
  } else {
    "/usr/bin/ps"
  }
  let (code, output, _) = @process.collect_output(ps, [
    "-A", "-o", "pid=,pgid=,stat=",
  ]) catch {
    _ => return []
  }
  if code != 0 {
    return []
  }
  let text = output.text() catch { _ => return [] }
  let result : Array[ProcStat] = []
  for line in text.split("\n") {
    let parts : Array[String] = []
    for piece in line.split(" ") {
      if piece != "" {
        parts.push(piece.to_string())
      }
    }
    if parts.length() < 3 {
      continue
    }
    let pid = match pty_parse_pid(parts[0][:]) {
      Some(value) => value
      None => continue
    }
    let pgrp = match pty_parse_pid(parts[1][:]) {
      Some(value) => value
      None => continue
    }
    let state = parts[2]
    result.push({
      pid,
      pgrp,
      zombie: state.has_prefix("Z") || state.has_prefix("X"),
    })
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
