///|
/// M1 host entry point. `serve` runs the real host; `status` and
/// `subscribe` are the smoke-test client built on `monexus/host-client`.
async fn main {
  let args = @env.args()
  let (code, message) = run_host_command(args) catch {
    error => (2, "monexus-host: " + error.to_string())
  }
  if message != "" {
    println(message)
  }
  @env.exit(code)
}

///|
async fn run_host_command(args : Array[String]) -> (Int32, String) {
  let command = if args.length() > 1 { args[1] } else { "version" }
  match command {
    "version" => (0, host_version_line())
    "help" | "--help" | "-h" => (0, usage_text())
    "serve" => serve_command(args[2:].to_owned())
    "status" => status_command(args[2:].to_owned())
    "subscribe" => subscribe_command(args[2:].to_owned())
    _ =>
      (
        2,
        "monexus-host: unknown command " +
        command +
        "\n" +
        usage_text(),
      )
  }
}

///|
const HOST_VERSION : String = "0.1.0-m1"

///|
fn host_version_line() -> String {
  "monexus-host " + HOST_VERSION + " (M1)"
}

///|
fn usage_text() -> String {
  [
    "usage:",
    "  monexus-host version",
    "  monexus-host serve [--state-dir DIR] [--heartbeat-ms N] [--port N]",
    "  monexus-host status [--state-dir DIR]",
    "  monexus-host subscribe [--state-dir DIR] [--since SEQ]",
    "      [--timeout-ms N] [--max-events N]",
    "",
    "`serve` writes DIR/host.json (mode 0600), binds a random loopback port",
    "and serves JSON-RPC 2.0 over WebSocket. Default DIR: $MONEXUS_STATE_DIR,",
    "then $HOME/.monexus.",
  ].join("\n")
}

///|
/// Parse `--key value`, `--key=value`, and a trailing `--` argv tail.
fn parse_pairs(
  args : Array[String],
) -> (Array[(String, String)], Array[String]) {
  let pairs : Array[(String, String)] = []
  let rest : Array[String] = []
  let mut index = 0
  while index < args.length() {
    let arg = args[index]
    if arg == "--" {
      index = index + 1
      while index < args.length() {
        rest.push(args[index])
        index = index + 1
      }
      break
    }
    if arg.has_prefix("--") {
      match arg.split_once("=") {
        Some((key, value)) => {
          pairs.push((key.to_owned(), value.to_owned()))
          index = index + 1
        }
        None => {
          let key = arg
          if index + 1 < args.length() {
            pairs.push((key, args[index + 1]))
            index = index + 2
          } else {
            pairs.push((key, ""))
            index = index + 1
          }
        }
      }
    } else {
      rest.push(arg)
      index = index + 1
    }
  }
  (pairs, rest)
}

///|
fn pair_last_opt(pairs : Array[(String, String)], key : String) -> String? {
  let mut found : String? = None
  for pair in pairs {
    if pair.0 == key {
      found = Some(pair.1)
    }
  }
  found
}

///|
fn pair_last(
  pairs : Array[(String, String)],
  key : String,
  default : String,
) -> String {
  match pair_last_opt(pairs, key) {
    Some(value) => value
    None => default
  }
}

///|
fn pair_int(
  pairs : Array[(String, String)],
  key : String,
  default : Int,
) -> Int {
  match pair_last_opt(pairs, key) {
    Some(value) => @string.parse_int(value) catch { _ => default }
    None => default
  }
}

///|
fn pair_int64(
  pairs : Array[(String, String)],
  key : String,
) -> Int64? {
  match pair_last_opt(pairs, key) {
    Some(value) => Some(@string.parse_int64(value) catch { _ => 0L })
    None => None
  }
}

///|
fn request_id(prefix : String) -> String {
  @contracts.new_id(prefix, @async.now())
}

///|
async fn serve_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let options = HostOptions::new(
    state_dir=pair_last(pairs, "--state-dir", @client.default_state_dir()),
    heartbeat_ms=pair_int(pairs, "--heartbeat-ms", 1_000),
    port=pair_int(pairs, "--port", 0),
  )
  @signal.set_global_cancellation_signals(
    [@signal.SIGINT, @signal.SIGTERM],
  )
  match serve(options) {
    Ok(_) => (0, "")
    Err(message) => (1, "monexus-host: " + message)
  }
}

///|
async fn status_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let state_dir = pair_last(
    pairs,
    "--state-dir",
    @client.default_state_dir(),
  )
  let info = match @client.read_host_info(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: offline: " + message)
  }
  let client = match @client.connect(info) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: offline: " + message)
  }
  let status = match client.call_host_status(request_id("req")) {
    Ok(value) => value
    Err(message) => {
      client.close()
      return (1, "monexus-host: offline: " + message)
    }
  }
  client.close()
  let lines : Array[String] = [
    "host online",
    "host_id=" + status.host_id,
    "version=" + status.version,
    "port=" + info.port.to_string(),
    "ws_url=" + info.ws_url,
    "started_at=" + status.started_at,
    "uptime_ms=" + status.uptime_ms.to_string(),
    "event_seq=" + status.event_seq.to_string(),
  ]
  (0, lines.join("\n"))
}

///|
async fn subscribe_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let state_dir = pair_last(
    pairs,
    "--state-dir",
    @client.default_state_dir(),
  )
  let timeout_ms = pair_int(pairs, "--timeout-ms", 5_000).max(1)
  let max_events = pair_int(pairs, "--max-events", 3).max(1)
  let since = pair_int64(pairs, "--since")
  let info = match @client.read_host_info(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: offline: " + message)
  }
  let client = match @client.connect(info) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: offline: " + message)
  }
  let subscribed = match client.subscribe(request_id("req"), since) {
    Ok(value) => value
    Err(message) => {
      client.close()
      return (1, "monexus-host: subscribe failed: " + message)
    }
  }
  let lines : Array[String] = [
    "subscribed=true replayed=" +
    subscribed.replayed.to_string() +
    " next_seq=" +
    subscribed.next_seq.to_string(),
  ]
  let outcome = @async.with_timeout_opt(
    timeout_ms,
    async fn() -> Result[Int, String] {
      let mut count = 0
      while count < max_events {
        let event = match client.wait_event() {
          Ok(value) => value
          Err(message) => return Err(message)
        }
        lines.push(
          "event seq=" +
          event.seq.to_string() +
          " type=" +
          event.event_type +
          " ts=" +
          event.ts +
          " subject=" +
          event.subject,
        )
        count = count + 1
      }
      Ok(count)
    },
  )
  client.close()
  match outcome {
    Some(Ok(_)) => (0, lines.join("\n"))
    Some(Err(message)) => {
      lines.push("subscribe error: " + message)
      (1, lines.join("\n"))
    }
    None => {
      lines.push(
        "subscribe timeout after " + timeout_ms.to_string() + "ms",
      )
      (1, lines.join("\n"))
    }
  }
}
