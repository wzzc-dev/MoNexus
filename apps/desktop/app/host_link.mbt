///|
const RECONNECT_DELAY_MS : Int = 1_500

///|
fn request_id(prefix : String) -> String {
  @contracts.new_id(prefix, @async.now())
}

///|
fn trace_link(line : String) -> Unit {
  match @env.get_env_var("MONEXUS_LINK_TRACE") {
    Some(value) if value != "" && value != "0" => println(line)
    _ => ()
  }
}

///|
fn dispatch(msg : Msg) -> Unit {
  match dispatch_cell.val {
    Some(dispatch) => dispatch(msg)
    None => ()
  }
}

///|
/// Background worker: read host.json, connect, publish host.status, subscribe
/// to events and reconnect with a fixed backoff whenever the host goes away.
/// It runs as a sibling task of the MoUI window and is cancelled on exit.
pub async fn host_link_loop(state_dir : String) -> Unit {
  for ;; {
    dispatch(LinkConnecting)
    trace_link("link connecting")
    let info = match @client.read_host_info(state_dir) {
      Ok(value) => value
      Err(message) => {
        dispatch(LinkOffline("host.json: " + message))
        trace_link("link offline host.json: " + message)
        @async.sleep(RECONNECT_DELAY_MS)
        continue
      }
    }
    let client = match @client.connect(info) {
      Ok(value) => value
      Err(message) => {
        dispatch(LinkOffline(message))
        trace_link("link offline " + message)
        @async.sleep(RECONNECT_DELAY_MS)
        continue
      }
    }
    let status = match client.call_host_status(request_id("req")) {
      Ok(value) => value
      Err(message) => {
        dispatch(LinkOffline(message))
        trace_link("link offline " + message)
        client.close()
        @async.sleep(RECONNECT_DELAY_MS)
        continue
      }
    }
    match client.subscribe(request_id("req"), None) {
      Ok(_) => ()
      Err(message) => {
        dispatch(LinkOffline(message))
        trace_link("link offline " + message)
        client.close()
        @async.sleep(RECONNECT_DELAY_MS)
        continue
      }
    }
    dispatch(
      LinkOnline({
        host_id: status.host_id,
        version: status.version,
        ws_url: info.ws_url,
        token_status: if info.token == "" {
          "missing"
        } else {
          "present (host.json, never displayed)"
        },
        state_dir: status.state_dir,
        event_seq: status.event_seq,
      }),
    )
    trace_link("link online " + info.ws_url)
    // Reconnect implies the projection may have changed while the desktop was
    // away (or the host restarted); pull the machine list once.
    enqueue_machine_command(RefreshMachines)
    enqueue_machine_command(AgentList)
    enqueue_machine_command(DecisionList(@contracts.DECISION_STATUS_PENDING))
    // The Projects page lists every open workspace, not just the one this
    // window last selected; load it on every (re)connect.
    enqueue_machine_command(ProjectList)
    // Tasks board and Activity replay after a reconnect; EventsLoaded dedupes
    // on seq so a stale cursor is safe.
    enqueue_machine_command(TaskRefresh(0L))
    let mut connected = true
    while connected {
      match client.wait_event() {
        Ok(event) => {
          dispatch(EventArrived(event.event_type, event.seq))
          if event.event_type == @contracts.EVENT_DECISION_REQUESTED ||
            event.event_type == @contracts.EVENT_DECISION_RESPONDED ||
            event.event_type == @contracts.EVENT_DECISION_EXPIRED {
            enqueue_machine_command(
              DecisionList(@contracts.DECISION_STATUS_PENDING),
            )
          }
          match @contracts.machine_event_removed_id(event) {
            Some(machine_id) => dispatch(MachineRemoved(machine_id))
            None =>
              match @contracts.machine_event_record(event) {
                Some(record) => dispatch(MachineUpserted(record))
                None => ()
              }
          }
        }
        Err(message) => {
          dispatch(LinkOffline(message))
          trace_link("link offline " + message)
          connected = false
        }
      }
    }
    client.close()
    @async.sleep(RECONNECT_DELAY_MS)
  }
}
