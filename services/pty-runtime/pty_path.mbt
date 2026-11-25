///|
/// Path and identifier validation shared by the PTY runtime. All checks are
/// byte-oriented and reject control characters; paths are only accepted
/// after `realpath`, so symlinks cannot redirect the session state or cwd.

///|
fn pty_join(parent : String, child : String) -> String {
  if parent.has_suffix("/") {
    parent + child
  } else {
    parent + "/" + child
  }
}

///|
fn pty_is_within(child : String, parent : String) -> Bool {
  child == parent || child.has_prefix(parent + "/")
}

///|
fn pty_has_control(value : String) -> Bool {
  for index in 0..<value.length() {
    let code = value.at(index).to_int()
    if code < 32 || code == 127 {
      return true
    }
  }
  false
}

///|
fn pty_has_nul(value : String) -> Bool {
  for index in 0..<value.length() {
    if value.at(index).to_int() == 0 {
      return true
    }
  }
  false
}

///|
fn pty_is_alnum(code : Int) -> Bool {
  (code >= 48 && code <= 57) ||
  (code >= 65 && code <= 90) ||
  (code >= 97 && code <= 122)
}

///|
fn pty_is_env_name_start(code : Int) -> Bool {
  (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95
}

///|
fn pty_is_env_name_char(code : Int) -> Bool {
  pty_is_env_name_start(code) || (code >= 48 && code <= 57)
}

///|
/// A stable session id becomes a path component, so it is restricted to a
/// conservative identifier alphabet and can never be `.` or `..`.
fn pty_valid_session_id(value : String) -> Bool {
  if value.length() == 0 || value.length() > 64 {
    return false
  }
  if pty_has_control(value) || pty_has_nul(value) {
    return false
  }
  let first = value.at(0).to_int()
  if !pty_is_alnum(first) {
    return false
  }
  for index in 0..<value.length() {
    let code = value.at(index).to_int()
    if !(pty_is_alnum(code) || code == 45 || code == 46 || code == 95) {
      return false
    }
  }
  true
}

///|
fn pty_valid_client_request_id(value : String) -> Bool {
  value.length() <= 128 && !pty_has_control(value) && !pty_has_nul(value)
}

///|
fn pty_valid_env_name(value : String) -> Bool {
  if value.length() == 0 || value.length() > 128 {
    return false
  }
  if !pty_is_env_name_start(value.at(0).to_int()) {
    return false
  }
  for index in 0..<value.length() {
    if !pty_is_env_name_char(value.at(index).to_int()) {
      return false
    }
  }
  true
}

///|
/// Names which would hand the child the user's SSH agent, SSH configuration
/// or a dynamic-loader injection point. `HOME` is intentionally not denied:
/// many tools require it and the runtime never reads `~/.ssh` itself.
fn pty_denied_env_name(name : String) -> Bool {
  let upper = name.to_upper()
  if upper.has_prefix("SSH_") {
    return true
  }
  if upper == "GIT_SSH" || upper == "GIT_SSH_COMMAND" ||
    upper == "GIT_ASKPASS" || upper == "SSH_ASKPASS" {
    return true
  }
  if upper == "LD_PRELOAD" || upper == "LD_LIBRARY_PATH" ||
    upper == "DYLD_INSERT_LIBRARIES" || upper == "DYLD_LIBRARY_PATH" {
    return true
  }
  false
}

///|
fn pty_has_ssh_component(path : String) -> Bool {
  for part in path.split("/") {
    if part == ".ssh" {
      return true
    }
  }
  false
}

///|
fn pty_valid_cwd(cwd : String) -> Bool {
  cwd.length() > 0 && cwd.has_prefix("/") && !pty_has_control(cwd) &&
  !pty_has_nul(cwd)
}
