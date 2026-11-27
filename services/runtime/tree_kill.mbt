///|
/// Process-tree cancellation for hosts without `setsid(1)` (macOS).
///
/// `runtime.exec` and `runtime.process` normally wrap a child in `setsid` so
/// the child's pid is also its process-group id and `kill(-pid)` reaches the
/// whole tree. macOS ships no `setsid` binary, so the child stays in the
/// runtime's own process group and a group signal would be wrong (it could
/// hit the node itself). Instead, enumerate the child's descendants with
/// `ps -A -o pid=,ppid=` and signal each pid directly.
///
/// The root is frozen with `SIGSTOP` before the walk: the child can be
/// cancelled in the few milliseconds between `spawn` and its first `fork`,
/// and a TERM to a still-running root would let a just-forked child escape the
/// snapshot and keep the run's pipes open. Stopping the root (and every
/// descendant found) makes the snapshot final, so a later KILL cannot orphan
/// new children. The helper runs inside a cancellation handler; it shields its
/// own short waits with `protect_from_cancel` and only uses direct `kill(1)`
/// calls, never waiting for another task.

///|
async fn ps_table() -> Array[(Int, Int)] {
  let ps = match first_existing(["/bin/ps", "/usr/bin/ps"]) {
    Some(path) => path
    None => return []
  }
  let (code, out, _) = @process.collect_output(ps, [
    "-A", "-o", "pid=,ppid=",
  ]) catch {
    _ => return []
  }
  let text = out.text() catch { _ => return [] }
  if code != 0 {
    return []
  }
  let rows : Array[(Int, Int)] = []
  for line in text.split("\n") {
    let parts : Array[String] = []
    for piece in line.split(" ") {
      if piece != "" {
        parts.push(piece.to_string())
      }
    }
    if parts.length() >= 2 {
      let child = @string.parse_int(parts[0]) catch { _ => -1 }
      let parent = @string.parse_int(parts[1]) catch { _ => -1 }
      if child > 0 && parent >= 0 {
        rows.push((child, parent))
      }
    }
  }
  rows
}

///|
async fn process_descendants(pid : Int) -> Array[Int] {
  let rows = ps_table()
  let seen : Array[Int] = [pid]
  let descendants : Array[Int] = []
  let mut added = true
  while added {
    added = false
    for row in rows {
      let (child, parent) = row
      if seen.contains(parent) && !seen.contains(child) {
        seen.push(child)
        descendants.push(child)
        added = true
      }
    }
  }
  descendants
}

///|
async fn signal_pid(signal : String, pid : Int) -> Unit {
  let kill = kill_path_global.val
  if kill == "" || pid <= 1 {
    return
  }
  // A pid can exit between the scan and the signal; capture the diagnostic
  // instead of letting `kill` write "No such process" to the node's stderr.
  let _ = @process.collect_output(kill, [
    "-" + signal, "--", pid.to_string(),
  ]) catch {
    _ => return
  }
}

///|
/// Collect the descendants of a root that has already been stopped. Every
/// newly discovered pid is stopped too, so a descendant cannot fork while the
/// walk is still in progress; repeating until a scan adds nothing makes the
/// snapshot final.
async fn collect_stopped_descendants(root : Int) -> Array[Int] {
  let known : Array[Int] = []
  let deadline = @async.now() + 250L
  let mut stable_scans = 0
  while @async.now() < deadline && stable_scans < 2 {
    let before = known.length()
    for child in process_descendants(root) {
      if !known.contains(child) {
        known.push(child)
        signal_pid("STOP", child)
      }
    }
    if known.length() == before {
      stable_scans = stable_scans + 1
    } else {
      stable_scans = 0
    }
    if stable_scans < 2 {
      @async.sleep(10)
    }
  }
  known
}

///|
/// Cancellation handler used when the child could not be made a session
/// leader. Freeze the tree, take a stable snapshot of it, then KILL the root
/// before any survivor: a stopped root cannot fork, so every child remains in
/// the snapshot instead of being orphaned with the run's pipes still open.
async fn cancel_process_tree(pid : Int32) -> Unit {
  let root = pid.to_int()
  if root <= 1 {
    return
  }
  @async.protect_from_cancel(async fn() -> Unit {
    signal_pid("STOP", root)
    // `kill(2)` reports a queued signal, not delivered state; give the root a
    // moment to enter the stopped state before taking the first snapshot.
    @async.sleep(20)
    let descendants = collect_stopped_descendants(root)
    signal_pid("KILL", root)
    for child in descendants {
      signal_pid("KILL", child)
    }
  })
}
