///|
/// Machine commands run on their own RPC connection, separate from the event
/// subscription. `RpcClient::request` skips notifications, so sending a
/// machine command on the event socket would silently drop machine events;
/// two connections keep the TEA loop fed.
let machine_command_queue : @aqueue.Queue[MachineCommand] = @aqueue.Queue(
  kind=Unbounded,
)

///|
/// Called from a program Effect (UI thread) and from the host-link worker
/// (after subscribe) to request machine work.
pub fn enqueue_machine_command(command : MachineCommand) -> Unit {
  ignore(machine_command_queue.try_put(command) catch { _ => false })
}

///|
fn machine_notice(command : MachineCommand, detail : String) -> String {
  match command {
    AddMachine(_) => "added: " + detail
    ProbeMachine(_) => "probe: " + detail
    RemoveMachine(_) => "removed: " + detail
    RefreshMachines => detail
    OpenProject(_, _) => "project: " + detail
    ProjectListFiles(_, _) => detail
    ProjectReadFile(_, path) => "read: " + path
    ProjectWriteFile(_, path, _) => "saved: " + path
    ProjectGitStatus(_) => "git status updated"
    ProjectGitDiff(_, _) => "diff updated"
    ProjectOpenTerminal(_) => "terminal: " + detail
    ProjectTerminalWrite(_, _, _) => "terminal input sent"
    ProjectTerminalRead(_) => "terminal output read"
    ProjectCloseTerminal(_) => "terminal closed"
    ProjectListWorktrees(_) => detail
    ProjectCreateWorktree(_, branch, _) => "worktree " + branch + " created"
    AgentProbe(agent_id, _, _) => "probe " + agent_id + ": " + detail
    AgentStart(agent_id, _, _, _, _) => "agent " + agent_id + ": " + detail
    AgentSend(_, _) => "prompt sent"
    AgentStop(_) => "session stopped"
    AgentResume(_) => "session resumed"
    AgentList => detail
    DecisionList(_) => detail
    DecisionRespond(_, _, _, _) => "decision answered"
  }
}

///|
fn git_status_text(status : @contracts.GitStatus) -> String {
  if !status.is_git {
    return "not a git repository"
  }
  let lines : Array[String] = [
    "branch " +
    (if status.branch == "" { "(detached)" } else { status.branch }) +
    (if status.upstream == "" {
      ""
    } else {
      " -> " + status.upstream
    }) +
    (if status.ahead > 0 { " ahead " + status.ahead.to_string() } else { "" }) +
    (if status.behind > 0 { " behind " + status.behind.to_string() } else { "" }),
  ]
  if status.changes.is_empty() {
    lines.push("clean")
  } else {
    for change in status.changes {
      lines.push(change.status + " " + change.path)
    }
  }
  lines.join("\n")
}

///|
async fn dispatch_project_status(
  client : @client.RpcClient,
  workspace_id : String,
) -> Unit {
  let id = request_id("cmd")
  match
    client.call_json(
      id,
      @contracts.METHOD_WORKSPACE_GIT_STATUS,
      @contracts.workspace_git_status_params(id, workspace_id),
    ) {
    Ok(json) =>
      match @contracts.git_status_result_value(json) {
        Ok(status) => dispatch(ProjectStatus(git_status_text(status)))
        Err(message) => dispatch(ProjectError(message))
      }
    Err(message) => dispatch(ProjectError("git status: " + message))
  }
}

///|
async fn dispatch_project_entries(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
) -> Unit {
  let id = request_id("cmd")
  match
    client.call_json(
      id,
      @contracts.METHOD_WORKSPACE_LIST_FILES,
      @contracts.workspace_list_params(id, workspace_id, path),
    ) {
    Ok(json) =>
      match @contracts.workspace_entries_from_json(json) {
        Ok(entries) => dispatch(ProjectEntries(entries))
        Err(message) => dispatch(ProjectError(message))
      }
    Err(message) => dispatch(ProjectError("list: " + message))
  }
}

///|
async fn dispatch_project_diff(
  client : @client.RpcClient,
  workspace_id : String,
  path : String,
) -> Unit {
  let id = request_id("cmd")
  match
    client.call_json(
      id,
      @contracts.METHOD_WORKSPACE_GIT_DIFF,
      @contracts.workspace_git_diff_params(id, workspace_id, path, false, ""),
    ) {
    Ok(json) =>
      match @contracts.git_diff_result_value(json) {
        Ok(diff) =>
          dispatch(
            ProjectDiff(
              if diff.text == "" {
                "(no diff for " + path + ")"
              } else if diff.truncated {
                diff.text + "\n(diff truncated)"
              } else {
                diff.text
              },
            ),
          )
        Err(message) => dispatch(ProjectError(message))
      }
    Err(message) => dispatch(ProjectError("diff: " + message))
  }
}

///|
/// One command per connection. Commands are rare (user actions and one list
/// refresh per reconnect), so reconnecting is simpler and more robust than
/// keeping a second long-lived socket in sync with host restarts.
async fn execute_machine_command(
  state_dir : String,
  command : MachineCommand,
) -> Unit {
  let info = match @client.read_host_info(state_dir) {
    Ok(value) => value
    Err(message) => {
      dispatch(MachineError("host offline: " + message))
      return
    }
  }
  let client = match @client.connect(info) {
    Ok(value) => value
    Err(message) => {
      dispatch(MachineError("host offline: " + message))
      return
    }
  }
  match command {
    AddMachine(draft) => {
      let port = @string.parse_int(draft.port.trim().to_owned()) catch {
        _ => 0
      }
      match client.call_machine_add(
        request_id("cmd"),
        name=draft.name,
        host=draft.host,
        port=port,
        user=draft.user,
        identity=draft.identity,
        use_ssh_config=draft.use_ssh_config,
        host_key_policy=draft.host_key_policy,
        known_hosts_file=draft.known_hosts_file,
      ) {
        Ok(record) => {
          dispatch(MachineUpserted(record))
          dispatch(
            MachineNotice(
              machine_notice(command, record.name + " (" + record.status + ")"),
            ),
          )
          dispatch(DraftCleared)
        }
        Err(message) => dispatch(MachineError(message))
      }
    }
    ProbeMachine(machine_id) => {
      match client.call_machine_probe(
        request_id("cmd"),
        machine_id,
        timeout_seconds=10,
      ) {
        Ok(view) => {
          dispatch(MachineUpserted(view.machine))
          dispatch(
            MachineNotice(
              machine_notice(
                command,
                view.machine.name +
                " " +
                machine_status_text(view.machine.status) +
                " · " +
                machine_profile_summary(view.machine),
              ),
            ),
          )
        }
        Err(message) => dispatch(MachineError(message))
      }
    }
    RemoveMachine(machine_id) => {
      match client.call_machine_remove(request_id("cmd"), machine_id) {
        Ok(removed) => {
          dispatch(MachineRemoved(removed))
          dispatch(MachineNotice(machine_notice(command, removed)))
        }
        Err(message) => dispatch(MachineError(message))
      }
    }
    RefreshMachines => {
      match client.call_machine_list(request_id("cmd")) {
        Ok(machines) => dispatch(MachinesLoaded(machines))
        Err(message) => dispatch(MachineError(message))
      }
    }
    OpenProject(machine_id, root) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_WORKSPACE_OPEN,
          @contracts.workspace_open_params(id, machine_id, root),
        ) {
        Ok(json) =>
          match @contracts.workspace_result_record(json) {
            Ok(record) => {
              dispatch(ProjectOpened(record))
              dispatch_project_entries(client, record.id, "")
              dispatch_project_status(client, record.id)
              let trees_id = request_id("cmd")
              match
                client.call_json(
                  trees_id,
                  @contracts.METHOD_WORKTREE_LIST,
                  @contracts.worktree_list_params(trees_id, record.id),
                ) {
                Ok(trees) =>
                  match @contracts.worktree_list_from_json(trees) {
                    Ok(records) => dispatch(ProjectWorktrees(records))
                    Err(_) => ()
                  }
                Err(_) => ()
              }
            }
            Err(message) => dispatch(ProjectError(message))
          }
        Err(message) => dispatch(ProjectError("open: " + message))
      }
    }
    ProjectListFiles(workspace_id, path) =>
      dispatch_project_entries(client, workspace_id, path)
    ProjectReadFile(workspace_id, path) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_WORKSPACE_READ,
          @contracts.workspace_read_params(id, workspace_id, path),
        ) {
        Ok(json) =>
          match @contracts.workspace_text_from_json(json) {
            Ok(text) => {
              dispatch(ProjectFile(path, text))
              dispatch_project_diff(client, workspace_id, path)
            }
            Err(message) => dispatch(ProjectError(message))
          }
        Err(message) => dispatch(ProjectError("read: " + message))
      }
    }
    ProjectWriteFile(workspace_id, path, content) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_WORKSPACE_WRITE,
          @contracts.workspace_write_params(id, workspace_id, path, content),
        ) {
        Ok(_) => {
          dispatch(ProjectNotice("saved " + path))
          dispatch_project_status(client, workspace_id)
          dispatch_project_diff(client, workspace_id, path)
        }
        Err(message) => dispatch(ProjectError("write: " + message))
      }
    }
    ProjectGitStatus(workspace_id) =>
      dispatch_project_status(client, workspace_id)
    ProjectGitDiff(workspace_id, path) =>
      dispatch_project_diff(client, workspace_id, path)
    ProjectOpenTerminal(workspace_id) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_TERMINAL_OPEN,
          @contracts.terminal_open_params(id, workspace_id, "", 24, 80),
        ) {
        Ok(json) =>
          match @contracts.terminal_open_from_json(json) {
            Some(opened) => dispatch(ProjectTerminalOpened(opened.session_id))
            None => dispatch(ProjectError("terminal.open: malformed result"))
          }
        Err(message) => dispatch(ProjectError("terminal.open: " + message))
      }
    }
    ProjectTerminalWrite(session_id, data, cursor) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_TERMINAL_WRITE,
          @contracts.terminal_write_params(id, session_id, data + "\n"),
        ) {
        Ok(_) => {
          @async.sleep(350)
          let read_id = request_id("cmd")
          match
            client.call_json(
              read_id,
              @contracts.METHOD_TERMINAL_READ,
              @contracts.terminal_read_params(read_id, session_id, cursor),
            ) {
            Ok(json) =>
              match @contracts.terminal_read_from_json(json) {
                Some(read) =>
                  dispatch(ProjectTerminalOutput(read.cursor, read.text))
                None => dispatch(ProjectError("terminal.read: malformed result"))
              }
            Err(message) => dispatch(ProjectError("terminal.read: " + message))
          }
        }
        Err(message) => dispatch(ProjectError("terminal.write: " + message))
      }
    }
    ProjectTerminalRead(session_id) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_TERMINAL_READ,
          @contracts.terminal_read_params(id, session_id, 0L),
        ) {
        Ok(json) =>
          match @contracts.terminal_read_from_json(json) {
            Some(read) => dispatch(ProjectTerminalOutput(read.cursor, read.text))
            None => dispatch(ProjectError("terminal.read: malformed result"))
          }
        Err(message) => dispatch(ProjectError("terminal.read: " + message))
      }
    }
    ProjectCloseTerminal(session_id) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_TERMINAL_CLOSE,
          @contracts.terminal_close_params(id, session_id),
        ) {
        Ok(_) => dispatch(ProjectNotice("terminal closed"))
        Err(message) => dispatch(ProjectError("terminal.close: " + message))
      }
    }
    ProjectListWorktrees(workspace_id) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_WORKTREE_LIST,
          @contracts.worktree_list_params(id, workspace_id),
        ) {
        Ok(json) =>
          match @contracts.worktree_list_from_json(json) {
            Ok(records) => dispatch(ProjectWorktrees(records))
            Err(message) => dispatch(ProjectError(message))
          }
        Err(message) => dispatch(ProjectError("worktree.list: " + message))
      }
    }
    ProjectCreateWorktree(workspace_id, branch, path) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_WORKTREE_CREATE,
          @contracts.worktree_create_params(id, workspace_id, branch, path, ""),
        ) {
        Ok(json) =>
          match @contracts.worktree_result_record(json) {
            Ok(record) => dispatch(ProjectWorktreeCreated(record))
            Err(message) => dispatch(ProjectError(message))
          }
        Err(message) => dispatch(ProjectError("worktree.create: " + message))
      }
    }
    AgentProbe(agent_id, mode, command) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_AGENT_PROBE,
          @contracts.agent_probe_params(
            id,
            agent_id,
            mode,
            command,
            [],
            "",
            Map([]),
          ),
        ) {
        Ok(json) =>
          match @contracts.agent_readiness_from_result(json) {
            Ok(readiness) =>
              dispatch(
                AgentNotice(
                  if readiness.ok {
                    "ready: " +
                    readiness.agent_name +
                    " " +
                    readiness.agent_version +
                    " · loadSession " +
                    (if readiness.load_session { "yes" } else { "no" })
                  } else {
                    "not ready: " + readiness.error
                  },
                ),
              )
            Err(message) => dispatch(AgentError(message))
          }
        Err(message) => dispatch(AgentError("agent.probe: " + message))
      }
    }
    AgentStart(agent_id, mode, workspace_id, worktree_id, prompt) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_AGENT_START,
          @contracts.agent_start_params(
            id,
            agent_id,
            mode,
            "",
            [],
            "",
            workspace_id,
            worktree_id,
            prompt,
            4_096,
            Map([]),
          ),
        ) {
        Ok(json) =>
          match @contracts.agent_session_from_result(json) {
            Ok(record) => {
              dispatch(AgentStarted(record))
              enqueue_agent_stream(record.id)
            }
            Err(message) => dispatch(AgentError(message))
          }
        Err(message) => dispatch(AgentError("agent.start: " + message))
      }
    }
    AgentSend(session_id, text) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_AGENT_SEND,
          @contracts.agent_send_params(id, session_id, text),
        ) {
        Ok(_) => dispatch(AgentNotice("prompt sent"))
        Err(message) => dispatch(AgentError("agent.send: " + message))
      }
    }
    AgentStop(session_id) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_AGENT_STOP,
          @contracts.agent_stop_params(id, session_id),
        ) {
        Ok(_) => dispatch(AgentNotice("session stopped"))
        Err(message) => dispatch(AgentError("agent.stop: " + message))
      }
    }
    AgentResume(session_id) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_AGENT_RESUME,
          @contracts.agent_resume_params(id, session_id),
        ) {
        Ok(json) =>
          match @contracts.agent_session_from_result(json) {
            Ok(record) => {
              dispatch(AgentStarted(record))
              enqueue_agent_stream(record.id)
            }
            Err(message) => dispatch(AgentError(message))
          }
        Err(message) => dispatch(AgentError("agent.resume: " + message))
      }
    }
    AgentList => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_AGENT_LIST,
          @contracts.agent_list_params(id, ""),
        ) {
        Ok(json) =>
          match @contracts.agent_sessions_from_result(json) {
            Ok(records) => dispatch(AgentSessions(records))
            Err(message) => dispatch(AgentError(message))
          }
        Err(message) => dispatch(AgentError("agent.list: " + message))
      }
    }
    DecisionList(status) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_DECISION_LIST,
          @contracts.decision_list_params(id, status, ""),
        ) {
        Ok(json) =>
          match @contracts.decision_list_from_result(json) {
            Ok(records) => dispatch(InboxDecisions(records))
            Err(message) => dispatch(AgentError(message))
          }
        Err(message) => dispatch(AgentError("decision.list: " + message))
      }
    }
    DecisionRespond(decision_id, option_id, text, answered_by) => {
      let id = request_id("cmd")
      match
        client.call_json(
          id,
          @contracts.METHOD_DECISION_RESPOND,
          @contracts.decision_respond_params(
            id,
            decision_id,
            option_id,
            text,
            answered_by,
          ),
        ) {
        Ok(json) =>
          match @contracts.decision_from_result(json) {
            Ok(record) =>
              dispatch(
                AgentNotice(
                  "decision " +
                  record.id +
                  ": " +
                  record.status +
                  (if record.delivery_error == "" {
                    ""
                  } else {
                    " · " + record.delivery_error
                  }),
                ),
              )
            Err(message) => dispatch(AgentError(message))
          }
        Err(message) => dispatch(AgentError("decision.respond: " + message))
      }
    }
  }
  client.close()
}

///|
/// Session ids that need a streaming poll loop. One entry per started or
/// resumed session; the loop ends when the session reaches a terminal state.
let agent_stream_queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)

///|
fn enqueue_agent_stream(session_id : String) -> Unit {
  ignore(agent_stream_queue.try_put(session_id) catch { _ => false })
}

///|
async fn dispatch_pending_decisions(client : @client.RpcClient) -> Unit {
  let id = request_id("cmd")
  match
    client.call_json(
      id,
      @contracts.METHOD_DECISION_LIST,
      @contracts.decision_list_params(
        id,
        @contracts.DECISION_STATUS_PENDING,
        "",
      ),
    ) {
    Ok(json) =>
      match @contracts.decision_list_from_result(json) {
        Ok(records) => dispatch(InboxDecisions(records))
        Err(message) => dispatch(AgentError("decision.list: " + message))
      }
    Err(message) => dispatch(AgentError("decision.list: " + message))
  }
}

///|
/// Poll `agent.read` for one session. This is the M4 streaming path: the
/// desktop polls a cursor and appends the delta, while the host keeps the
/// transcript bounded. The loop stops as soon as the host reports a terminal
/// state (stopped/exited/failed).
pub async fn agent_stream_loop(state_dir : String) -> Unit {
  for ;; {
    let session_id = agent_stream_queue.get() catch { _ => return }
    let info = match @client.read_host_info(state_dir) {
      Ok(value) => value
      Err(message) => {
        dispatch(AgentError("host offline: " + message))
        continue
      }
    }
    let client = match @client.connect(info) {
      Ok(value) => value
      Err(message) => {
        dispatch(AgentError("host offline: " + message))
        continue
      }
    }
    let mut cursor = 0L
    let mut last_pending = ""
    let mut active = true
    while active {
      let id = request_id("stream")
      match
        client.call_json(
          id,
          @contracts.METHOD_AGENT_READ,
          @contracts.agent_read_params(id, session_id, cursor),
        ) {
        Ok(json) =>
          match @contracts.agent_read_from_json(json) {
            Some(read) => {
              cursor = read.cursor
              dispatch(
                AgentStreamState(
                  session_id,
                  read.state,
                  read.stop_reason,
                  read.pending_decision,
                ),
              )
              if read.text != "" {
                dispatch(AgentStreamText(read.cursor, read.text))
              }
              if read.pending_decision != last_pending {
                last_pending = read.pending_decision
                dispatch_pending_decisions(client)
              }
              if !@contracts.agent_state_is_active(read.state) {
                active = false
              }
            }
            None => {
              dispatch(AgentError("agent.read: malformed result"))
              active = false
            }
          }
        Err(message) => {
          dispatch(AgentError("agent.read: " + message))
          active = false
        }
      }
      if active {
        @async.sleep(300)
      }
    }
    client.close()
  }
}

///|
/// Background worker: serial command execution. Started beside the MoUI
/// window and the host-link worker; the task group cancels it on exit.
pub async fn machine_command_loop(state_dir : String) -> Unit {
  for ;; {
    let command = machine_command_queue.get() catch { _ => return }
    execute_machine_command(state_dir, command)
  }
}
