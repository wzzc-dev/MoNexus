///|
/// Runtime node host mode (A1.2b).
///
/// `monexus-host runtime pair|serve|status` (also reachable as
/// `monexus-host --runtime ...`) is the node-side entry point paired with one
/// primary over pinned TLS. It owns only execution state: identity, a 0600
/// bearer token, the runtime core's state root and a rooted workspace. It
/// stores no org/task/approval state and cannot answer Decisions; the policy
/// gate fails closed until a snapshot is installed (A1.3b), with
/// `--allow-workspace` as the documented single-machine override.

///|
fn runtime_usage() -> String {
  [
    "usage:",
    "  monexus-host runtime pair --runtime-id ID --primary HOST:PORT",
    "      --ca FILE --pin SHA256 --code CODE [--state-base DIR]",
    "      [--workspace DIR] [--server-name NAME] [--heartbeat-ms N]",
    "  monexus-host runtime serve --runtime-id ID --primary HOST:PORT",
    "      --ca FILE --pin SHA256 [--state-base DIR] [--workspace DIR]",
    "      [--server-name NAME] [--heartbeat-ms N] [--backoff-ms N]",
    "      [--max-attempts N] [--allow-workspace true|false]",
    "  monexus-host runtime status --runtime-id ID [--state-base DIR]",
    "  monexus-host --runtime ...   (same commands; serve is the default)",
    "",
    "The runtime node stores its identity and token under",
    "<state-base>/<runtime-id>/ (0700 dir, 0600 files). Default state-base:",
    "$MONEXUS_RUNTIME_DIR, then $HOME/.monexus/runtime. TLS is always pinned:",
    "--pin is the leaf certificate SHA-256 and there is no plaintext fallback.",
  ].join("\n")
}

///|
fn runtime_address(text : String) -> Result[(String, Int), String] {
  match text.rev_split_once(":") {
    Some((host, port_text)) => {
      if host == "" {
        return Err("--primary needs HOST:PORT")
      }
      let port = @string.parse_int(port_text) catch {
        _ => return Err("--primary port is not a number")
      }
      if port <= 0 || port > 65_535 {
        return Err("--primary port is out of range")
      }
      Ok((host.to_owned(), port))
    }
    None => Err("--primary needs HOST:PORT")
  }
}

///|
fn runtime_heartbeat_ms(pairs : Array[(String, String)]) -> Int64 {
  match pair_last_opt(pairs, "--heartbeat-ms") {
    Some(value) => @string.parse_int64(value) catch { _ => 5_000L }
    None => 5_000L
  }
}

///|
/// Build the node's pinned TLS client config and session policy from CLI
/// flags. The token is never a flag: it is read from the 0600 state file.
fn runtime_node_config(
  pairs : Array[(String, String)],
  runtime_id : String,
) -> Result[@transport.NodeConfig, String] {
  let primary = pair_last(pairs, "--primary", "")
  if primary == "" {
    return Err("missing --primary HOST:PORT")
  }
  let (host, port) = match runtime_address(primary) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let ca = pair_last(pairs, "--ca", "")
  if ca == "" {
    return Err("missing --ca (the primary CA certificate file)")
  }
  let pin = pair_last(pairs, "--pin", "")
  if pin == "" {
    return Err("missing --pin (the pinned leaf certificate SHA-256)")
  }
  let server_name = pair_last(pairs, "--server-name", host)
  let max_attempts = pair_int(pairs, "--max-attempts", 0)
  let backoff_ms = match pair_last_opt(pairs, "--backoff-ms") {
    Some(value) => @string.parse_int64(value) catch { _ => 0L }
    None => 0L
  }
  let tls = @transport.TlsClientConfig::new(
    host~,
    port~,
    ca_certificate_file=ca,
    expected_leaf_sha256=pin.trim().to_lower().to_owned(),
    server_name~,
  )
  let config = @transport.NodeConfig::new(
    runtime_id~,
    tls~,
    heartbeat_interval_ms=runtime_heartbeat_ms(pairs),
    poll_timeout_ms=20L,
    backoff_base_ms=if backoff_ms > 0L { backoff_ms } else { 1_000L },
    backoff_cap_ms=if backoff_ms > 0L { backoff_ms } else { 60_000L },
    jitter_ms=0L,
    max_attempts~,
  )
  Ok(config)
}

///|
async fn runtime_open_host(
  pairs : Array[(String, String)],
  runtime_id : String,
) -> Result[@runtime_node.NodeHost, String] {
  let state_base = pair_last(
    pairs,
    "--state-base",
    @runtime_node.node_default_state_base(),
  )
  let workspace = pair_last(pairs, "--workspace", "")
  @runtime_node.NodeHost::open(
    runtime_id,
    state_base~,
    workspace_root=workspace,
    policy=None,
  )
}

///|
async fn runtime_pair_command(pairs : Array[(String, String)]) -> (Int32, String) {
  let runtime_id = pair_last(pairs, "--runtime-id", "")
  if runtime_id == "" {
    return (2, "monexus-host: runtime pair needs --runtime-id\n" + runtime_usage())
  }
  let code = pair_last(pairs, "--code", "")
  if code == "" {
    return (2, "monexus-host: runtime pair needs --code\n" + runtime_usage())
  }
  let config = match runtime_node_config(pairs, runtime_id) {
    Ok(value) => value
    Err(message) => return (2, "monexus-host: runtime pair: " + message)
  }
  let host = match runtime_open_host(pairs, runtime_id) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: runtime pair: " + message)
  }
  let grant = match host.pair(config, code) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: runtime pair: " + message)
  }
  (
    0,
    "runtime " + grant.runtime_id +
    " paired; token saved to " + host.token_path(),
  )
}

///|
async fn runtime_serve_command(pairs : Array[(String, String)]) -> (Int32, String) {
  let runtime_id = pair_last(pairs, "--runtime-id", "")
  if runtime_id == "" {
    return (2, "monexus-host: runtime serve needs --runtime-id\n" + runtime_usage())
  }
  let config = match runtime_node_config(pairs, runtime_id) {
    Ok(value) => value
    Err(message) => return (2, "monexus-host: runtime serve: " + message)
  }
  let host = match runtime_open_host(pairs, runtime_id) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: runtime serve: " + message)
  }
  if pair_bool(pairs, "--allow-workspace", false) {
    host.set_policy(@runtime_node.PolicyGate::allow_workspace(host.workspace_root()))
  }
  let outcome = host.serve(config)
  match outcome {
    @transport.NodeRunOutcome::Drained => (0, "runtime " + runtime_id + " drained")
    @transport.NodeRunOutcome::Revoked => (1, "runtime " + runtime_id + " revoked")
    @transport.NodeRunOutcome::Unauthorized => {
      (1, "runtime " + runtime_id + " unauthorized")
    }
    @transport.NodeRunOutcome::AttemptsExhausted(attempts) => {
      (
        1,
        "runtime " +
        runtime_id +
        " gave up after " +
        attempts.to_string() +
        " attempts",
      )
    }
    @transport.NodeRunOutcome::Stopped(message) => {
      (1, "runtime " + runtime_id + " stopped: " + message)
    }
  }
}

///|
async fn runtime_status_command(pairs : Array[(String, String)]) -> (Int32, String) {
  let runtime_id = pair_last(pairs, "--runtime-id", "")
  if runtime_id == "" {
    return (2, "monexus-host: runtime status needs --runtime-id\n" + runtime_usage())
  }
  let host = match runtime_open_host(pairs, runtime_id) {
    Ok(value) => value
    Err(message) => return (1, "monexus-host: runtime status: " + message)
  }
  let has_token = @fs.exists(host.token_path()) catch { _ => false }
  let lines : Array[String] = [
    "runtime=" + runtime_id,
    "state_dir=" + host.state_dir(),
    "workspace=" + host.workspace_root(),
    "paired=" + (if has_token { "yes" } else { "no" }),
    "token=" + host.token_path(),
  ]
  (0, lines.join("\n"))
}

///|
async fn runtime_command(args : Array[String]) -> (Int32, String) {
  let known = ["pair", "serve", "status", "help", "--help", "-h"]
  let sub = if args.length() > 0 && known.contains(args[0]) {
    args[0]
  } else {
    "serve"
  }
  let rest = if sub == "serve" && (args.length() == 0 || !known.contains(args[0])) {
    args
  } else {
    args[1:].to_owned()
  }
  match sub {
    "pair" => runtime_pair_command(parse_pairs(rest).0)
    "status" => runtime_status_command(parse_pairs(rest).0)
    "help" | "--help" | "-h" => (0, runtime_usage())
    _ => runtime_serve_command(parse_pairs(rest).0)
  }
}
