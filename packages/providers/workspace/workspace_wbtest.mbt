///|
/// M6 durable poll parsing: dead panes are reported, exit markers win, and
/// the log tail is copied byte-for-byte (an empty log stays empty).
test "durable poll: dead pane, exit marker and exact log text" {
  let exited = parse_durable_poll("__ALIVE__\n__DEAD__0\n__EXIT__7\n__LOG__\nbuild failed\n")
  assert_true(exited.alive)
  assert_true(exited.dead)
  assert_eq(exited.dead_status, 0)
  assert_true(exited.exited)
  assert_eq(exited.exit_code, 7)
  assert_eq(exited.output, "build failed\n")

  let died = parse_durable_poll("__ALIVE__\n__DEAD__137\n__LOG__\n")
  assert_true(died.dead)
  assert_eq(died.dead_status, 137)
  assert_false(died.exited)
  assert_eq(died.output, "")

  let empty = parse_durable_poll("__ALIVE__\n__LOG__\n")
  assert_false(empty.dead)
  assert_eq(empty.output, "")

  let running = parse_durable_poll("__ALIVE__\n__LOG__\nstill running")
  assert_false(running.dead)
  assert_false(running.exited)
  assert_eq(running.output, "still running")
}

///|
/// A log line that looks like a marker must not change poll state once the
/// log section has started.
test "durable poll: log content cannot spoof markers" {
  let poll = parse_durable_poll("__ALIVE__\n__LOG__\n__DEAD__1\n__EXIT__0\n")
  assert_false(poll.dead)
  assert_false(poll.exited)
  assert_eq(poll.output, "__DEAD__1\n__EXIT__0\n")
}

///|
async fn wait_for_terminal_text(
  output : @aqueue.Queue[TerminalEvent],
  collected : StringBuilder,
  needle : String,
) -> Bool {
  for ;; {
    let event = output.get() catch { _ => return false }
    match event {
      Data(text) => {
        collected.write_string(text)
        if collected.to_string().contains(needle) {
          return true
        }
      }
      Eof => return collected.to_string().contains(needle)
    }
  }
}

///|
/// The local workspace terminal must forward a resize request to its PTY.
/// The shell prints its initial size, waits for input, then prints the size
/// again after the resize; observing both proves the ioctl reached the PTY.
async test "local terminal resize reaches the PTY" {
  let dir = @fs.tmpdir(prefix="monexus-workspace-terminal-resize-")
  defer @fs.rmdir(dir, recursive=true)
  let input : @aqueue.Queue[TerminalInput] = @aqueue.Queue(kind=Unbounded)
  let output : @aqueue.Queue[TerminalEvent] = @aqueue.Queue(kind=Unbounded)
  let provider = Local({ root: dir, git_root: "", is_git: false })
  let completed = @async.with_timeout_opt(10_000, async fn() -> Bool {
    @async.with_task_group(async fn(group) -> Bool {
      group.spawn_bg(() => {
        provider.run_terminal(
          "resize-test",
          "stty size; read _; stty size",
          24,
          80,
          input,
          output,
        )
      })
      let collected = StringBuilder()
      if !wait_for_terminal_text(output, collected, "24 80") {
        return false
      }
      input.put(Resize(30, 100)) catch { _ => return false }
      input.put(Data("\n")) catch { _ => return false }
      let resized = wait_for_terminal_text(output, collected, "30 100")
      input.put(Close) catch { _ => () }
      resized
    })
  })
  match completed {
    Some(true) => ()
    Some(false) => fail("local terminal did not report the resized PTY dimensions")
    None => fail("local terminal resize test timed out")
  }
}
