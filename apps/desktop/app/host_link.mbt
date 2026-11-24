///|
const RECONNECT_DELAY_MS : Int = 1_500

///|
fn request_id(prefix : String) -> String {
  @contracts.new_id(prefix, @async.now())
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
    let info = match @client.read_host_info(state_dir) {
      Ok(value) => value
      Err(message) => {
        dispatch(LinkOffline("host.json: " + message))
        @async.sleep(RECONNECT_DELAY_MS)
        continue
      }
    }
    let client = match @client.connect(info) {
      Ok(value) => value
      Err(message) => {
        dispatch(LinkOffline(message))
        @async.sleep(RECONNECT_DELAY_MS)
        continue
      }
    }
    let status = match client.call_host_status(request_id("req")) {
      Ok(value) => value
      Err(message) => {
        dispatch(LinkOffline(message))
        client.close()
        @async.sleep(RECONNECT_DELAY_MS)
        continue
      }
    }
    match client.subscribe(request_id("req"), None) {
      Ok(_) => ()
      Err(message) => {
        dispatch(LinkOffline(message))
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
        event_seq: status.event_seq,
      }),
    )
    let mut connected = true
    while connected {
      match client.wait_event() {
        Ok(event) =>
          dispatch(EventArrived(event.event_type, event.seq))
        Err(message) => {
          dispatch(LinkOffline(message))
          connected = false
        }
      }
    }
    client.close()
    @async.sleep(RECONNECT_DELAY_MS)
  }
}
