///|
/// Loopback SSH coverage. The shell owns the ephemeral sshd, keys and
/// known_hosts file; this flow only speaks the typed host RPC contract.
async fn ssh_workspace_flow(
  env : SmokeEnv,
  client : @client.RpcClient,
  report : Report,
) -> Unit {
  let machine_id = match client.call_machine_add(
    smoke_request_id("machine"),
    name="loopback",
    host="127.0.0.1",
    port=env.ssh_port,
    user=env.ssh_user,
    identity=env.ssh_identity,
    use_ssh_config=false,
    host_key_policy=@contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    known_hosts_file=env.known_hosts,
  ) {
    Ok(record) => {
      report.pass("machine.add returned " + record.id)
      record.id
    }
    Err(message) => {
      report.fail("machine.add returned an id", message)
      ""
    }
  }
  if machine_id == "" {
    return
  }

  match client.call_machine_probe(
    smoke_request_id("probe"),
    machine_id,
    timeout_seconds=15,
  ) {
    Ok(view) =>
      if view.machine.status == @contracts.MACHINE_STATUS_ONLINE {
        report.pass("SSH machine probes online")
      } else {
        report.fail("SSH machine probes online", view.machine.status)
      }
    Err(message) => report.fail("SSH machine probes online", message)
  }

  let remote_ws = match open_workspace(client, machine_id, env.remote_root) {
    Ok(record) => {
      report.pass("SSH workspace.open returned " + record.id)
      report.eq(
        "SSH workspace kind is ssh",
        @contracts.WORKSPACE_KIND_SSH,
        record.kind,
      )
      report.eq(
        "SSH workspace sees the git root",
        "true",
        bool_text(record.is_git),
      )
      record.id
    }
    Err(message) => {
      report.fail("SSH workspace.open returned an id", message)
      report.fail("SSH workspace kind is ssh", message)
      report.fail("SSH workspace sees the git root", message)
      ""
    }
  }
  if remote_ws == "" {
    return
  }

  match list_files(client, remote_ws, "") {
    Ok(entries) => {
      let text = entries_to_text(entries)
      report.contains("SSH listFiles includes README.md", "README.md", text)
      report.contains(
        "SSH listFiles includes the moved notes file directory",
        "docs",
        text,
      )
    }
    Err(message) => {
      report.fail("SSH listFiles includes README.md", message)
      report.fail("SSH listFiles includes the moved notes file directory", message)
    }
  }
  match read_workspace_file(client, remote_ws, "README.md") {
    Ok(text) =>
      report.eq("SSH read returns file text", "hello m3 updated", shell_text(text))
    Err(message) => report.fail("SSH read returns file text", message)
  }
  match write_workspace_file(client, remote_ws, "remote.txt", "from-ssh\n") {
    Ok(_) => report.pass("SSH write acknowledged")
    Err(message) => report.fail("SSH write acknowledged", message)
  }
  report.eq(
    "SSH write is visible on disk",
    "from-ssh",
    read_text_trim(env.remote_root + "/remote.txt"),
  )
  let names = directory_names(env.remote_root)
  if names.contains("monexus-tmp") {
    report.fail("SSH write left no temp file behind", names)
  } else {
    report.pass("SSH write left no temp file behind")
  }
  match stat_workspace_path(client, remote_ws, "remote.txt") {
    Ok(stat) => report.eq("SSH stat kind is file", "file", stat.kind)
    Err(message) => report.fail("SSH stat kind is file", message)
  }
  match git_status(client, remote_ws) {
    Ok(status) => {
      let changes = git_changes_text(status)
      report.contains(
        "SSH git status sees the remote.txt change",
        "remote.txt",
        changes,
      )
    }
    Err(message) =>
      report.fail("SSH git status sees the remote.txt change", message)
  }
  match git_diff(client, remote_ws, "README.md") {
    Ok(diff) =>
      report.contains(
        "SSH git diff returns the modified README",
        "hello m3 updated",
        diff.text,
      )
    Err(message) =>
      report.fail("SSH git diff returns the modified README", message)
  }

  let ssh_terminal = match
    open_terminal(client, remote_ws, "printf m3-ssh-ok\\n", 24, 80) {
    Ok(record) => {
      report.pass("SSH terminal.open returned " + record.session_id)
      record.session_id
    }
    Err(message) => {
      report.fail("SSH terminal.open returned a session", message)
      ""
    }
  }
  if ssh_terminal != "" {
    @async.sleep(2000)
    match read_terminal(client, ssh_terminal, 0L) {
      Ok(payload) =>
        report.contains(
          "SSH terminal (ssh -tt) produced command output",
          "m3-ssh-ok",
          payload.text,
        )
      Err(message) =>
        report.fail("SSH terminal (ssh -tt) produced command output", message)
    }
    let _ = close_terminal(client, ssh_terminal)
  } else {
    report.fail("SSH terminal (ssh -tt) produced command output", "no session")
  }

  let resize_terminal_id = match
    open_terminal(
      client,
      remote_ws,
      "while true; do stty size; sleep 1; done",
      24,
      80,
    ) {
    Ok(record) => {
      report.pass("SSH resize terminal.open returned " + record.session_id)
      record.session_id
    }
    Err(message) => {
      report.fail("SSH resize terminal.open returned a session", message)
      ""
    }
  }
  if resize_terminal_id != "" {
    let initial = poll_terminal_text(
      client,
      resize_terminal_id,
      0L,
      "24 80",
      15,
    )
    let resize_cursor = match initial {
      Ok(poll) => {
        report.pass("SSH PTY initial stty size is 24 80")
        poll.cursor
      }
      Err(message) => {
        report.fail("SSH PTY initial stty size is 24 80", message)
        0L
      }
    }
    match resize_terminal(client, resize_terminal_id, 30, 100) {
      Ok(result) => {
        report.eq(
          "SSH terminal.resize acknowledged rows=30",
          "30",
          result.rows.to_string(),
        )
        report.eq(
          "SSH terminal.resize acknowledged cols=100",
          "100",
          result.cols.to_string(),
        )
      }
      Err(message) => {
        report.fail("SSH terminal.resize acknowledged rows=30", message)
        report.fail("SSH terminal.resize acknowledged cols=100", message)
      }
    }
    match poll_terminal_text(
      client,
      resize_terminal_id,
      resize_cursor,
      "30 100",
      15,
    ) {
      Ok(_) => report.pass("SSH PTY resize reaches remote stty size 30 100")
      Err(message) =>
        report.fail("SSH PTY resize reaches remote stty size 30 100", message)
    }
    let _ = close_terminal(client, resize_terminal_id)
  } else {
    report.fail("SSH PTY initial stty size is 24 80", "no session")
    report.fail("SSH terminal.resize acknowledged rows=30", "no session")
    report.fail("SSH terminal.resize acknowledged cols=100", "no session")
    report.fail("SSH PTY resize reaches remote stty size 30 100", "no session")
  }

  let tmux_terminal = match open_terminal(client, remote_ws, "", 24, 80) {
    Ok(record) => {
      report.pass("SSH interactive terminal opened a tmux-backed session")
      record.session_id
    }
    Err(message) => {
      report.fail("SSH interactive terminal opened a tmux-backed session", message)
      ""
    }
  }
  if tmux_terminal == "" {
    report.fail("SSH tmux session accepts terminal.write", "no session")
    report.fail("SSH tmux reports its real pane size before resize", "no session")
    report.fail("SSH tmux reports its real pane size after resize", "no session")
    report.fail("SSH tmux pane row delta follows resize (24 -> 30 requested)", "")
    report.fail("SSH tmux pane col delta follows resize (80 -> 100 requested)", "")
    report.fail("SSH tmux pane sizes were captured for delta evidence", "")
    return
  }

  let tmux_cursor = match
    retry_terminal_write(
      client,
      tmux_terminal,
      0L,
      "printf '%s\\n' m3-ssh-tmux-ok\n",
      "m3-ssh-tmux-ok",
      15,
    ) {
    Ok(poll) => {
      report.pass("SSH tmux session accepts terminal.write")
      poll.cursor
    }
    Err(message) => {
      report.fail("SSH tmux session accepts terminal.write", message)
      0L
    }
  }
  let _ = write_terminal(
    client,
    tmux_terminal,
    "printf 'TMUX_SIZE_BEFORE '; stty size\n",
  )
  let before_poll = poll_tmux_size(
    client,
    tmux_terminal,
    tmux_cursor,
    "TMUX_SIZE_BEFORE",
    15,
  )
  let (before_rows, before_cols, before_cursor) = match before_poll {
    Ok(poll) => {
      report.pass(
        "SSH tmux reports its real pane size before resize (" +
        poll.rows.to_string() +
        " " +
        poll.cols.to_string() +
        ")",
      )
      (poll.rows, poll.cols, poll.cursor)
    }
    Err(message) => {
      report.fail("SSH tmux reports its real pane size before resize", message)
      (0, 0, tmux_cursor)
    }
  }
  let _ = resize_terminal(client, tmux_terminal, 30, 100)
  @async.sleep(500)
  let _ = write_terminal(
    client,
    tmux_terminal,
    "printf 'TMUX_SIZE_AFTER '; stty size\n",
  )
  let after_poll = poll_tmux_size(
    client,
    tmux_terminal,
    before_cursor,
    "TMUX_SIZE_AFTER",
    15,
  )
  let (after_rows, after_cols) = match after_poll {
    Ok(poll) => {
      report.pass(
        "SSH tmux reports its real pane size after resize (" +
        poll.rows.to_string() +
        " " +
        poll.cols.to_string() +
        ")",
      )
      (poll.rows, poll.cols)
    }
    Err(message) => {
      report.fail("SSH tmux reports its real pane size after resize", message)
      (0, 0)
    }
  }
  if before_rows > 0 && before_cols > 0 && after_rows > 0 && after_cols > 0 {
    report.eq(
      "SSH tmux pane row delta follows resize (24 -> 30 requested)",
      "6",
      (after_rows - before_rows).to_string(),
    )
    report.eq(
      "SSH tmux pane col delta follows resize (80 -> 100 requested)",
      "20",
      (after_cols - before_cols).to_string(),
    )
    report.pass(
      "SSH tmux pane observed " +
      before_rows.to_string() +
      " " +
      before_cols.to_string() +
      " -> " +
      after_rows.to_string() +
      " " +
      after_cols.to_string(),
    )
  } else {
    report.fail(
      "SSH tmux pane sizes were captured for delta evidence",
      "before=" +
      before_rows.to_string() +
      " " +
      before_cols.to_string() +
      " after=" +
      after_rows.to_string() +
      " " +
      after_cols.to_string(),
    )
  }
  let _ = write_terminal(client, tmux_terminal, "exit\n")
  @async.sleep(500)
  let _ = close_terminal(client, tmux_terminal)

  let remote_wt_dir = env.work + "/remote-wt"
  let remote_wt_id = match
    create_worktree(client, remote_ws, "m3-remote", remote_wt_dir) {
    Ok(record) => {
      report.pass("SSH worktree.create works over the same contract")
      record.id
    }
    Err(message) => {
      report.fail("SSH worktree.create", message)
      ""
    }
  }
  if path_exists(remote_wt_dir + "/.git") {
    report.pass("remote worktree checkout exists")
  } else {
    report.fail("remote worktree checkout exists", "")
  }
  if remote_wt_id != "" {
    let _ = remove_worktree(client, remote_wt_id)
  }
  match list_worktrees(client, remote_ws) {
    Ok(records) =>
      report.eq(
        "remote worktree archived",
        "[]",
        if records.length() == 0 {
          "[]"
        } else {
          "[" + worktrees_text(records) + "]"
        },
      )
    Err(message) => report.fail("remote worktree archived", message)
  }
}
