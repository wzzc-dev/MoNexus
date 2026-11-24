///|
/// Parse `--key value`, `--key=value`, and a trailing `--` argv tail.
/// Pairs keep their order so repeated flags (ACP `--arg`) survive.
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
fn pair_all(pairs : Array[(String, String)], key : String) -> Array[String] {
  let out : Array[String] = []
  for pair in pairs {
    if pair.0 == key {
      out.push(pair.1)
    }
  }
  out
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
/// Build the explicit SSH target from CLI flags. Test-only switches
/// (`--known-hosts`, `--strict`) become ordinary `-o` options, so they are
/// visible in the argv that actually runs (no hidden environment).
fn ssh_target_from_flags(
  pairs : Array[(String, String)],
) -> @ssh.SshTarget? {
  let host = pair_last(pairs, "--ssh-host", "")
  if host == "" {
    return None
  }
  let options : Array[String] = []
  let known_hosts = pair_last(pairs, "--known-hosts", "")
  if known_hosts != "" {
    options.push("UserKnownHostsFile=" + known_hosts)
  }
  let strict = pair_last(pairs, "--strict", "")
  if strict != "" {
    options.push("StrictHostKeyChecking=" + strict)
  }
  Some(
    @ssh.SshTarget::new(
      host~,
      port=pair_int(pairs, "--ssh-port", 22),
      identity=pair_last(pairs, "--identity", ""),
      timeout_seconds=pair_int(pairs, "--timeout", 10),
      extra_options=options,
    ),
  )
}

///|
async fn pty_check_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let shell = pair_last(pairs, "--shell", "sh")
  let command = pair_last(
    pairs,
    "--cmd",
    "printf 'M0_PTY_OK\\n'; exit 7",
  )
  let result = @pty.run_pty_check(shell, command)
  let lines : Array[String] = [
    "M0_PTY_SHELL=" + shell,
    "M0_PTY_PID=" + result.pid.to_string(),
    "M0_PTY_EXIT=" + result.exit_code.to_string(),
    "M0_PTY_OUTPUT_BEGIN",
    result.output,
    "M0_PTY_OUTPUT_END",
  ]
  (0, lines.join("\n"))
}

///|
async fn ssh_probe_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let target = match ssh_target_from_flags(pairs) {
    Some(target) => target
    None => return (2, "monexus-host: --ssh-host is required\n" + usage_text())
  }
  let profile = match @ssh.probe(
    target,
    timeout_seconds=pair_int(pairs, "--timeout", 15),
  ) {
    Ok(value) => value
    Err(error) => return (1, "M0_SSH_PROBE_FAILED " + error.to_string())
  }
  (0, "M0_SSH_PROBE_OK\n" + profile.render())
}

///|
async fn ssh_run_command(args : Array[String]) -> (Int32, String) {
  let (pairs, rest) = parse_pairs(args)
  let target = match ssh_target_from_flags(pairs) {
    Some(target) => target
    None => return (2, "monexus-host: --ssh-host is required\n" + usage_text())
  }
  if rest.is_empty() {
    return (2, "monexus-host: ssh-run needs an argv after `--`\n" + usage_text())
  }
  let result = match @ssh.run(
    target,
    rest,
    cwd=pair_last(pairs, "--cwd", "."),
    timeout_seconds=pair_int(pairs, "--timeout", 30),
  ) {
    Ok(value) => value
    Err(error) => return (1, "M0_SSH_RUN_FAILED " + error.to_string())
  }
  let lines : Array[String] = [
    "M0_SSH_RUN_EXIT=" + result.exit_code.to_string(),
    "M0_SSH_STDOUT_BEGIN",
    result.stdout,
    "M0_SSH_STDOUT_END",
    "M0_SSH_STDERR_BEGIN",
    result.stderr,
    "M0_SSH_STDERR_END",
  ]
  (result.exit_code, lines.join("\n"))
}

///|
async fn acp_command(args : Array[String]) -> (Int32, String) {
  let (pairs, _) = parse_pairs(args)
  let command = pair_last(pairs, "--command", "")
  if command == "" {
    return (2, "monexus-host: --command is required for acp\n" + usage_text())
  }
  let prompt = pair_last(pairs, "--prompt", "")
  if prompt == "" {
    return (2, "monexus-host: --prompt is required for acp\n" + usage_text())
  }
  let timeout_seconds = pair_int(pairs, "--timeout", 120)
  let config = @acp_client.AcpConfig::new(
    command~,
    args=pair_all(pairs, "--arg"),
    cwd=pair_last(pairs, "--cwd", ""),
    workspace=pair_last(pairs, "--workspace", "."),
  )
  println("M0_ACP_STREAM_BEGIN")
  let run = @async.with_timeout_opt(
    timeout_seconds.max(1) * 1_000,
    async fn() {
      @acp_client.run_prompt(config, prompt, text => {
        println("M0_ACP_CHUNK " + text)
      })
    },
  )
  let outcome = match run {
    Some(outcome) => outcome
    None => {
      return (
        1,
        "M0_ACP_STREAM_END\nM0_ACP_ERROR timeout after " +
        timeout_seconds.to_string() +
        "s",
      )
    }
  }
  let lines : Array[String] = [
    "M0_ACP_STREAM_END",
    "M0_ACP_SESSION_ID=" + outcome.session_id,
    "M0_ACP_AGENT=" + outcome.agent_name,
    "M0_ACP_CHUNKS=" + outcome.streamed_chunks.to_string(),
    "M0_ACP_UPDATES=" + outcome.updates.to_string(),
    "M0_ACP_PERMISSION_REQUESTS=" +
    outcome.permission_requests.to_string(),
    "M0_ACP_TEXT=" + outcome.agent_text,
  ]
  if outcome.ok {
    lines.push("M0_ACP_DONE stop_reason=" + outcome.stop_reason)
    (0, lines.join("\n"))
  } else {
    lines.push("M0_ACP_ERROR " + outcome.error)
    (1, lines.join("\n"))
  }
}
