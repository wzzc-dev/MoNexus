///|
/// One authenticated WebSocket connection to a MoNexus host.
///
/// M1 keeps at most one request in flight per connection. Notifications that
/// arrive while waiting for a response are ignored by `request`; callers that
/// want events use `wait_event` after `subscribe`.
pub struct RpcClient {
  conn : @websocket.Conn
  endpoint : String
}

///|
/// Connect to `info.ws_url` with the Bearer token from `host.json`.
pub async fn connect(
  info : @contracts.HostInfo,
) -> Result[RpcClient, String] {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([
    (
      @http.CaseInsensitiveString("Authorization"),
      "Bearer " + info.token,
    ),
  ])
  let conn = @websocket.connect(info.ws_url, headers=headers) catch {
    error =>
      return Err(
        "cannot connect to " + info.ws_url + ": " + error.to_string(),
      )
  }
  Ok({ conn, endpoint: info.ws_url })
}

///|
pub fn RpcClient::endpoint(self : RpcClient) -> String {
  self.endpoint
}

///|
pub fn RpcClient::close(self : RpcClient) -> Unit {
  self.conn.close()
}

///|
/// Receive one text frame and parse it as JSON. Binary frames are rejected:
/// the MoNexus protocol is JSON text only.
async fn RpcClient::recv_json(
  self : RpcClient,
) -> Result[@json.Json, String] {
  let message = self.conn.recv() catch {
    error => return Err("connection closed: " + error.to_string())
  }
  match message.kind {
    Text => {
      let text = message.read_all().text() catch {
        error => return Err("cannot read frame: " + error.to_string())
      }
      let json = @json.parse(text) catch {
        error =>
          return Err("invalid JSON frame: " + error.to_string())
      }
      Ok(json)
    }
    Binary => return Err("unexpected binary frame from host")
  }
}

///|
/// Send a request and wait for the response with the same id. Frames that are
/// not responses (notifications) are skipped, matching the single-in-flight
/// contract used in M1.
pub async fn RpcClient::request(
  self : RpcClient,
  id : String,
  method : String,
  params : Map[String, @json.Json],
) -> Result[@contracts.RpcResponse, String] {
  let frame = @contracts.RpcRequest::new(id, method, params).to_json()
  self.conn.send_text(frame.stringify()) catch {
    error => return Err("cannot send request: " + error.to_string())
  }
  for ;; {
    let json = match self.recv_json() {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    match @contracts.parse_response(json) {
      Ok(response) =>
        if response.id == id {
          return Ok(response)
        }
      Err(_) => ()
    }
  }
}

///|
fn response_error_text(error : @contracts.RpcError) -> String {
  "host error " + error.code.to_string() + ": " + error.message
}

///|
/// Call `host.status`. `client_request_id` doubles as the JSON-RPC request id
/// in M1, so retries of the same id get the host's cached response.
pub async fn RpcClient::call_host_status(
  self : RpcClient,
  client_request_id : String,
) -> Result[@contracts.HostStatus, String] {
  let response = match self.request(
    client_request_id,
    @contracts.METHOD_HOST_STATUS,
    @contracts.status_params(client_request_id),
  ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match response.error {
    Some(error) => return Err(response_error_text(error))
    None => ()
  }
  let result = match response.result {
    Some(value) => value
    None => return Err("host.status returned no result")
  }
  match @contracts.HostStatus::from_json(result) {
    Some(status) => Ok(status)
    None => return Err("host.status returned a malformed result")
  }
}

///|
/// Call `events.subscribe`. `since` replays events with `seq > since`.
pub async fn RpcClient::subscribe(
  self : RpcClient,
  client_request_id : String,
  since : Int64?,
) -> Result[@contracts.SubscribeResult, String] {
  let response = match self.request(
    client_request_id,
    @contracts.METHOD_EVENTS_SUBSCRIBE,
    @contracts.subscribe_params(client_request_id, since),
  ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match response.error {
    Some(error) => return Err(response_error_text(error))
    None => ()
  }
  let result = match response.result {
    Some(value) => value
    None => return Err("events.subscribe returned no result")
  }
  match @contracts.SubscribeResult::from_json(result) {
    Some(subscribed) => Ok(subscribed)
    None => return Err("events.subscribe returned a malformed result")
  }
}

///|
/// Send a machine RPC and decode its result. Machine errors carry a readable
/// `kind`/`reason` payload, so callers get `Unauthorized: ...`-style text
/// instead of the numeric JSON-RPC envelope.
async fn RpcClient::machine_call(
  self : RpcClient,
  client_request_id : String,
  method : String,
  params : Map[String, @json.Json],
) -> Result[@json.Json, String] {
  let response = match self.request(client_request_id, method, params) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match response.error {
    Some(error) => return Err(@contracts.machine_error_text(error))
    None => ()
  }
  match response.result {
    Some(value) => Ok(value)
    None => Err(method + " returned no result")
  }
}

///|
/// Register an SSH machine. The host stores the explicit target and records
/// the effective `ssh -G` view before answering.
pub async fn RpcClient::call_machine_add(
  self : RpcClient,
  client_request_id : String,
  name~ : String,
  host~ : String,
  port~ : Int = 22,
  user~ : String = "",
  identity~ : String = "",
  use_ssh_config~ : Bool = true,
  host_key_policy~ : String = @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
  known_hosts_file~ : String = "",
) -> Result[@contracts.MachineRecord, String] {
  let result = match self.machine_call(
    client_request_id,
    @contracts.METHOD_MACHINE_ADD,
    @contracts.machine_add_params(
      client_request_id,
      name~,
      host~,
      port~,
      user~,
      identity~,
      use_ssh_config~,
      host_key_policy~,
      known_hosts_file~,
    ),
  ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  @contracts.machine_record_from_json(result)
}

///|
pub async fn RpcClient::call_machine_list(
  self : RpcClient,
  client_request_id : String,
) -> Result[Array[@contracts.MachineRecord], String] {
  let result = match self.machine_call(
    client_request_id,
    @contracts.METHOD_MACHINE_LIST,
    @contracts.machine_list_params(client_request_id),
  ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  @contracts.machine_list_from_json(result)
}

///|
pub async fn RpcClient::call_machine_probe(
  self : RpcClient,
  client_request_id : String,
  machine_id : String,
  timeout_seconds~ : Int = 10,
) -> Result[@contracts.MachineProbeView, String] {
  let result = match self.machine_call(
    client_request_id,
    @contracts.METHOD_MACHINE_PROBE,
    @contracts.machine_probe_params(
      client_request_id,
      machine_id,
      timeout_seconds~,
    ),
  ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  @contracts.machine_probe_from_json(result)
}

///|
pub async fn RpcClient::call_machine_remove(
  self : RpcClient,
  client_request_id : String,
  machine_id : String,
) -> Result[String, String] {
  let result = match self.machine_call(
    client_request_id,
    @contracts.METHOD_MACHINE_REMOVE,
    @contracts.machine_remove_params(client_request_id, machine_id),
  ) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let object = match @contracts.as_object(result) {
    Some(value) => value
    None => return Err("machine.remove returned a malformed result")
  }
  match @contracts.string_field(object, "machine_id") {
    Some(value) => Ok(value)
    None => Err("machine.remove returned no machine_id")
  }
}

///|
/// Block until the next `events.event` notification and decode its envelope.
pub async fn RpcClient::wait_event(
  self : RpcClient,
) -> Result[@contracts.EventEnvelope, String] {
  for ;; {
    let json = match self.recv_json() {
      Ok(value) => value
      Err(message) => return Err(message)
    }
    match @contracts.parse_notification(json) {
      Ok(notification) =>
        if notification.method == @contracts.NOTIFICATION_EVENTS_EVENT {
          let payload = match notification.params.get("event") {
            Some(value) => value
            None => return Err("events.event notification has no event field")
          }
          match @contracts.EventEnvelope::from_json(payload) {
            Some(event) => return Ok(event)
            None => return Err("events.event notification is malformed")
          }
        }
      Err(_) => ()
    }
  }
}
