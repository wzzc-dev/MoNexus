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
    "version" | "--version" | "-V" => (0, host_version_line())
    "help" | "--help" | "-h" => (0, usage_text())
    "serve" => serve_command(args[2:].to_owned())
    "status" => status_command(args[2:].to_owned())
    "subscribe" => subscribe_command(args[2:].to_owned())
    "machine" => machine_command(args[2:].to_owned())
    "runtime" | "--runtime" => runtime_command(args[2:].to_owned())
    "rpc" => rpc_command(args[2:].to_owned())
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
const HOST_VERSION : String = @contracts.PRODUCT_VERSION

///|
fn host_version_line() -> String {
  @contracts.product_version_line("monexus-host")
}

///|
fn usage_text() -> String {
  [
    "usage:",
    "  monexus-host version | --version",
    "  monexus-host serve [--state-dir DIR] [--heartbeat-ms N] [--port N]",
    "      [--trigger-enabled true|false]  (default: $MONEXUS_TRIGGER_ENABLED, off)",
    "  monexus-host status [--state-dir DIR]",
    "  monexus-host subscribe [--state-dir DIR] [--since SEQ]",
    "      [--timeout-ms N] [--max-events N]",
    "  monexus-host machine add [--state-dir DIR] [--kind ssh|local|runtime] --host HOST",
    "      [--name NAME] [--port N] [--user USER] [--identity FILE]",
    "      [--use-ssh-config true|false]",
    "      [--host-key-policy accept-new|yes|no|config]",
    "      [--known-hosts-file FILE]",
    "  monexus-host machine list [--state-dir DIR]",
    "  monexus-host machine probe --id ID [--state-dir DIR]",
    "      [--timeout-seconds N]",
    "  monexus-host machine remove --id ID [--state-dir DIR]",
    "  monexus-host rpc --method METHOD [--state-dir DIR] [--params JSON]",
    "  monexus-host runtime pair|serve|status [--runtime-id ID] ...",
    "      (see `monexus-host runtime help`; also `--runtime ...`)",
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
  // A3.0 is off by default (ADR-0014 §7). The environment variable is only a
  // default; an explicit `--trigger-enabled` wins.
  let env_default = match @env.get_env_var("MONEXUS_TRIGGER_ENABLED") {
    Some(value) =>
      match value.to_lower() {
        "true" | "1" | "yes" | "on" => true
        _ => false
      }
    None => false
  }
  let options = HostOptions::new(
    state_dir=pair_last(pairs, "--state-dir", @client.default_state_dir()),
    heartbeat_ms=pair_int(pairs, "--heartbeat-ms", 1_000),
    port=pair_int(pairs, "--port", 0),
    trigger_enabled=pair_bool(pairs, "--trigger-enabled", env_default),
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

///|
fn pair_bool(
  pairs : Array[(String, String)],
  key : String,
  default : Bool,
) -> Bool {
  match pair_last_opt(pairs, key) {
    Some(value) =>
      match value.to_lower() {
        "true" | "1" | "yes" | "on" => true
        "false" | "0" | "no" | "off" => false
        _ => default
      }
    None => default
  }
}

///|
async fn connect_client(
  state_dir : String,
) -> Result[@client.RpcClient, String] {
  let info = match @client.read_host_info(state_dir) {
    Ok(value) => value
    Err(message) => return Err("offline: " + message)
  }
  @client.connect(info)
}

///|
fn sorted_effective_lines(
  record : @contracts.MachineRecord,
) -> Array[String] {
  let keys : Array[String] = []
  for key, _ in record.ssh_effective {
    keys.push(key)
  }
  keys.sort()
  let lines : Array[String] = []
  for key in keys {
    let value = match record.ssh_effective.get(key) {
      Some(item) => item
      None => ""
    }
    lines.push("ssh_effective." + key + "=" + value)
  }
  if record.ssh_effective_error != "" {
    lines.push("ssh_effective_error=" + record.ssh_effective_error)
  }
  lines
}

///|
fn machine_record_lines(record : @contracts.MachineRecord) -> Array[String] {
  let lines : Array[String] = [
    "id=" + record.id,
    "name=" + record.name,
    "target=" + record.target_label(),
    "port=" + record.port.to_string(),
    "status=" + record.status,
    "use_ssh_config=" + record.use_ssh_config.to_string(),
    "host_key_policy=" + record.host_key_policy,
    "identity=" + record.identity,
    "known_hosts_file=" + record.known_hosts_file,
    "last_seen=" + record.last_seen,
    "last_error=" + record.last_error,
    "updated_at=" + record.updated_at,
  ]
  for line in sorted_effective_lines(record) {
    lines.push(line)
  }
  lines
}

///|
fn profile_lines(profile : @contracts.MachineProfile) -> Array[String] {
  let lines : Array[String] = [
    "profile.os=" + profile.os,
    "profile.arch=" + profile.arch,
    "profile.hostname=" + profile.hostname,
    "profile.shell=" + profile.shell,
    "profile.max_parallel=" + profile.max_parallel.to_string(),
    "profile.has_docker=" + profile.has_docker.to_string(),
    "profile.has_gui=" + profile.has_gui.to_string(),
    "profile.notes=" + profile.notes,
  ]
  let tools : Array[String] = []
  for name, _ in profile.toolchains {
    tools.push(name)
  }
  tools.sort()
  for name in tools {
    let path = match profile.toolchains.get(name) {
      Some(value) => value
      None => ""
    }
    lines.push("profile.tool." + name + "=" + path)
  }
  lines
}

///|
fn machine_usage() -> String {
  [
    "usage:",
    "  monexus-host machine add [--state-dir DIR] [--kind ssh|local|runtime] --host HOST",
    "      [--name NAME] [--port N] [--user USER] [--identity FILE]",
    "      [--use-ssh-config true|false] [--host-key-policy POLICY]",
    "      [--known-hosts-file FILE]",
    "  monexus-host machine list [--state-dir DIR]",
    "  monexus-host machine probe --id ID [--state-dir DIR] [--timeout-seconds N]",
    "  monexus-host machine remove --id ID [--state-dir DIR]",
    "  monexus-host rpc --method METHOD [--state-dir DIR] [--params JSON]",
    "  monexus-host runtime pair|serve|status [--runtime-id ID] ...",
    "      (see `monexus-host runtime help`; also `--runtime ...`)",
    "",
    "POLICY is accept-new (default), yes, no or config.",
  ].join("\n")
}

///|
async fn machine_command(args : Array[String]) -> (Int32, String) {
  let sub = if args.length() > 0 { args[0] } else { "help" }
  match sub {
    "add" => machine_add_command(args[1:].to_owned())
    "list" => machine_list_command(args[1:].to_owned())
    "probe" => machine_probe_command(args[1:].to_owned())
    "remove" => machine_remove_command(args[1:].to_owned())
    "help" | "--help" | "-h" => (0, machine_usage())
    _ => (
      2,
      "monexus-host: unknown machine command " + sub + "\n" + machine_usage(),
    )
  }
}

///|
async fn machine_add_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let state_dir = pair_last(pairs, "--state-dir", @client.default_state_dir())
  let kind = pair_last(pairs, "--kind", @contracts.MACHINE_KIND_SSH)
  if kind != @contracts.MACHINE_KIND_SSH &&
    kind != @contracts.MACHINE_KIND_LOCAL &&
    kind != @contracts.MACHINE_KIND_RUNTIME {
    return (
      2,
      "monexus-host: machine add --kind must be ssh, local or runtime\n" +
      machine_usage(),
    )
  }
  let host = if kind == @contracts.MACHINE_KIND_LOCAL {
    "localhost"
  } else {
    pair_last(pairs, "--host", "")
  }
  if kind != @contracts.MACHINE_KIND_LOCAL && host == "" {
    return (2, "monexus-host: machine add needs --host\n" + machine_usage())
  }
  let client = match connect_client(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: " + message)
  }
  let record = match client.call_machine_add(
    request_id("req"),
    name=pair_last(pairs, "--name", if kind == @contracts.MACHINE_KIND_LOCAL {
      "this machine"
    } else {
      host
    }),
    host=host,
    kind~,
    port=if kind == @contracts.MACHINE_KIND_RUNTIME {
      0
    } else {
      pair_int(pairs, "--port", 22)
    },
    user=pair_last(pairs, "--user", ""),
    identity=pair_last(pairs, "--identity", ""),
    use_ssh_config=pair_bool(pairs, "--use-ssh-config", true),
    host_key_policy=pair_last(
      pairs,
      "--host-key-policy",
      @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    ),
    known_hosts_file=pair_last(pairs, "--known-hosts-file", ""),
  ) {
    Ok(value) => value
    Err(message) => {
      client.close()
      return (1, "monexus-host: machine add: " + message)
    }
  }
  client.close()
  (0, ["machine added"].join("\n") + "\n" + machine_record_lines(record).join("\n"))
}

///|
async fn machine_list_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let state_dir = pair_last(pairs, "--state-dir", @client.default_state_dir())
  let client = match connect_client(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: " + message)
  }
  let machines = match client.call_machine_list(request_id("req")) {
    Ok(value) => value
    Err(message) => {
      client.close()
      return (1, "monexus-host: machine list: " + message)
    }
  }
  client.close()
  let lines : Array[String] = []
  for record in machines {
    lines.push(
      "machine id=" +
      record.id +
      " status=" +
      record.status +
      " name=" +
      record.name +
      " target=" +
      record.target_label() +
      ":" +
      record.port.to_string() +
      (if record.last_error == "" {
        ""
      } else {
        " last_error=" + record.last_error
      }),
    )
  }
  lines.push("machines=" + machines.length().to_string())
  (0, lines.join("\n"))
}

///|
async fn machine_probe_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let state_dir = pair_last(pairs, "--state-dir", @client.default_state_dir())
  let machine_id = pair_last(pairs, "--id", "")
  if machine_id == "" {
    return (2, "monexus-host: machine probe needs --id\n" + machine_usage())
  }
  let timeout_seconds = pair_int(pairs, "--timeout-seconds", 10).max(1).min(120)
  let client = match connect_client(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: " + message)
  }
  let view = match client.call_machine_probe(
    request_id("req"),
    machine_id,
    timeout_seconds=timeout_seconds,
  ) {
    Ok(value) => value
    Err(message) => {
      client.close()
      return (1, "monexus-host: machine probe: " + message)
    }
  }
  client.close()
  let lines = machine_record_lines(view.machine)
  for line in profile_lines(view.profile) {
    lines.push(line)
  }
  (0, lines.join("\n"))
}

///|
async fn machine_remove_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let state_dir = pair_last(pairs, "--state-dir", @client.default_state_dir())
  let machine_id = pair_last(pairs, "--id", "")
  if machine_id == "" {
    return (2, "monexus-host: machine remove needs --id\n" + machine_usage())
  }
  let client = match connect_client(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: " + message)
  }
  let removed = match client.call_machine_remove(request_id("req"), machine_id) {
    Ok(value) => value
    Err(message) => {
      client.close()
      return (1, "monexus-host: machine remove: " + message)
    }
  }
  client.close()
  (0, "machine removed id=" + removed)
}

///|
fn rpc_usage() -> String {
  [
    "usage:",
    "  monexus-host rpc --method METHOD [--state-dir DIR] [--params JSON]",
    "  monexus-host runtime pair|serve|status [--runtime-id ID] ...",
    "      (see `monexus-host runtime help`; also `--runtime ...`)",
    "",
    "Sends one JSON-RPC request over the authenticated WebSocket and prints",
    "the raw result as JSON. client_request_id is added when absent, so M3",
    "workspace/worktree/lease/terminal calls can be driven from shell tests.",
  ].join("\n")
}

///|
async fn rpc_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let method = pair_last(pairs, "--method", "")
  if method == "" {
    return (2, "monexus-host: rpc needs --method\n" + rpc_usage())
  }
  let state_dir = pair_last(pairs, "--state-dir", @client.default_state_dir())
  let params_text = pair_last(pairs, "--params", "{}")
  let parsed = @json.parse(params_text) catch {
    error => return (2, "monexus-host: invalid --params JSON: " + error.to_string())
  }
  let object = match @contracts.as_object(parsed) {
    Some(value) => value
    None => return (2, "monexus-host: --params must be a JSON object")
  }
  let params : Map[String, @json.Json] = Map([])
  for key, value in object {
    params.set(key, value)
  }
  if params.get("client_request_id") is None {
    params.set("client_request_id", @contracts.json_string(request_id("req")))
  }
  let client = match connect_client(state_dir) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: " + message)
  }
  let result = match client.call_json(request_id("req"), method, params) {
    Ok(value) => value
    Err(message) => {
      client.close()
      return (1, "monexus-host: " + method + ": " + message)
    }
  }
  client.close()
  (0, result.stringify())
}
