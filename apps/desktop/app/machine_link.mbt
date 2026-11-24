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
  }
  client.close()
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
