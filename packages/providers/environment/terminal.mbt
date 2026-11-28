///|
/// Container terminal transport. The host chooses this path when an active
/// environment exists for the workspace/worktree; local sessions use a local
/// PTY in front of `docker exec -it`, SSH sessions use an SSH TTY in front of
/// the same docker argv.

///|
/// Consume one escape sequence starting at `start` (an ESC character) and
/// return the index of the next character to process. CSI sequences run to
/// their final byte, OSC sequences to BEL or `ESC \`; an unterminated sequence
/// swallows the rest of the chunk. Printable payload is never re-emitted.
fn skip_escape(text : String, start : Int) -> Int {
  let mut index = start + 1
  if index >= text.length() {
    return index
  }
  let introducer = match text.get_char(index) {
    Some(value) => value.to_int()
    None => return text.length()
  }
  if introducer == 91 {
    // CSI: ESC [ ... final-byte(0x40..0x7e)
    index = index + 1
    while index < text.length() {
      let code = match text.get_char(index) {
        Some(value) => value.to_int()
        None => return text.length()
      }
      if code >= 64 && code <= 126 {
        return index + 1
      }
      index = index + 1
    }
    return text.length()
  }
  if introducer == 93 {
    // OSC: ESC ] ... (BEL | ESC \)
    index = index + 1
    while index < text.length() {
      let code = match text.get_char(index) {
        Some(value) => value.to_int()
        None => return text.length()
      }
      if code == 7 {
        return index + 1
      }
      if code == 27 {
        let next = index + 1
        if next < text.length() &&
          text.get_char(next) == Some('\\') {
          return next + 1
        }
        return index + 1
      }
      index = index + 1
    }
    return text.length()
  }
  // A two-character escape (ESC followed by one byte): consume both.
  (start + 2).min(text.length())
}

///|
pub fn sanitize_terminal(text : String) -> String {
  let out = StringBuilder()
  let mut index = 0
  while index < text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => break
    }
    let code = ch.to_int()
    if code == 27 {
      index = skip_escape(text, index)
      continue
    }
    if code == 13 {
      out.write_char('\n')
      index = index + 1
      continue
    }
    if code == 7 || code == 8 {
      index = index + 1
      continue
    }
    if code == 10 || code == 9 || code >= 32 {
      out.write_char(ch)
    }
    index = index + 1
  }
  out.to_string()
}

///|
fn terminal_argv(
  identity : @docker.EnvironmentIdentity,
  command : String,
  workdir : String,
) -> Result[Array[String], EnvFailure] {
  let inner : Array[String] = if command.trim() == "" {
    ["sh", "-i"]
  } else {
    ["sh", "-c", command]
  }
  match @docker.exec_tty_argv(identity, inner, workdir=workdir) {
    Ok(value) => Ok(value)
    Err(error) => Err(env_failure_from_docker(error))
  }
}

///|
async fn pump_local_pty(
  pty : @pty.Pty,
  output : @aqueue.Queue[@workspace.TerminalEvent],
) -> Unit {
  for ;; {
    let chunk = pty.read_some() catch { _ => break }
    match chunk {
      Some(bytes) => {
        let text = @utf8.decode_lossy(bytes[:], ignore_bom=false)
        let clean = sanitize_terminal(text)
        if clean != "" {
          output.put(@workspace.TerminalEvent::Data(clean)) catch {
            _ => break
          }
        }
      }
      None => break
    }
  }
}

///|
async fn run_local_container_terminal(
  docker_argv : Array[String],
  cwd : String,
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[@workspace.TerminalInput],
  output : @aqueue.Queue[@workspace.TerminalEvent],
) -> Unit {
  let args : Array[StringView] = []
  for index in 1..<docker_argv.length() {
    args.push(docker_argv[index].to_string_view())
  }
  @async.with_task_group(async fn(group) {
    let pty = @pty.spawn(
      group,
      docker_argv[0],
      args,
      rows=rows,
      cols=cols,
      cwd=cwd,
      no_wait=true,
    ) catch {
      error => {
        output.put(
          @workspace.TerminalEvent::Data(
            "terminal: cannot spawn docker exec: " + error.to_string() + "\n",
          ),
        ) catch { _ => () }
        output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
        group.return_immediately(())
        return
      }
    }
    group.spawn_bg(() => {
      let inner = pump_local_pty(pty, output)
      inner
      output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
      group.return_immediately(())
    })
    for ;; {
      let item = input.get() catch { _ => break }
      match item {
        @workspace.TerminalInput::Data(text) =>
          pty.write(text) catch {
            _ => break
          }
        @workspace.TerminalInput::Resize(rows, cols) =>
          pty.resize(rows~, cols~) catch {
            _ => ()
          }
        @workspace.TerminalInput::Close => break
      }
    }
  })
  output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
  output.close()
}

///|
async fn run_ssh_container_terminal(
  target : @ssh.SshTarget,
  docker_argv : Array[String],
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[@workspace.TerminalInput],
  output : @aqueue.Queue[@workspace.TerminalEvent],
) -> Unit {
  let remote = @ssh.remote_exec_command(".", docker_argv)
  @workspace.run_ssh_pty_terminal(target, remote, rows, cols, input, output)
}

///|
async fn terminal_reject(
  output : @aqueue.Queue[@workspace.TerminalEvent],
  message : String,
) -> Unit {
  output.put(
    @workspace.TerminalEvent::Data("terminal: " + message + "\n"),
  ) catch { _ => () }
  output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
  output.close()
}

///|
pub async fn run_container_terminal(
  runner : DockerRunner,
  identity : @docker.EnvironmentIdentity,
  command : String,
  workdir : String,
  cwd : String,
  rows : Int32,
  cols : Int32,
  input : @aqueue.Queue[@workspace.TerminalInput],
  output : @aqueue.Queue[@workspace.TerminalEvent],
) -> Unit {
  // Only an owned, running container may be attached to.
  match container_ownership(runner, identity) {
    Ok(Owned(value)) =>
      if !value.running {
        terminal_reject(output, "environment container is not running")
        return
      }
    Ok(Absent) => {
      terminal_reject(
        output,
        "environment container " + @docker.container_name(identity) +
        " does not exist",
      )
      return
    }
    Ok(Foreign(_)) => {
      terminal_reject(
        output,
        "container labels do not match the environment record; left untouched",
      )
      return
    }
    Err(error) => {
      terminal_reject(output, error.to_string())
      return
    }
  }
  let docker_argv = match terminal_argv(identity, command, workdir) {
    Ok(value) => value
    Err(error) => {
      output.put(
        @workspace.TerminalEvent::Data("terminal: " + error.to_string() + "\n"),
      ) catch { _ => () }
      output.put(@workspace.TerminalEvent::Eof) catch { _ => () }
      output.close()
      return
    }
  }
  match runner.target {
    Some(target) => {
      let remote_argv : Array[String] = ["docker"]
      for item in docker_argv {
        remote_argv.push(item)
      }
      run_ssh_container_terminal(target, remote_argv, rows, cols, input, output)
    }
    None => {
      if runner.runtime {
        // A paired runtime node streams the same `docker exec -it` through a
        // node PTY. The argv excludes the `docker` name; the adapter resolves
        // it on the node PATH.
        match runner.terminal {
          Some(terminal) => {
            terminal(docker_argv, rows, cols, input, output)
            return
          }
          None => {
            terminal_reject(
              output,
              "runtime terminal transport is not attached",
            )
            return
          }
        }
      }
      let local_argv : Array[String] = [resolve_local_program("docker")]
      for item in docker_argv {
        local_argv.push(item)
      }
      run_local_container_terminal(local_argv, cwd, rows, cols, input, output)
    }
  }
}
