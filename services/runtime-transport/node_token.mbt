///|
/// Node-side credential token file.
///
/// The plaintext machine credential is the one secret the node must keep on
/// disk; it lives in a 0600 file inside a 0700 directory. Writes use a temp
/// file, `fsync` and an atomic rename. Loading refuses any mode other than
/// exactly 0600 rather than silently tightening it. No function here ever
/// returns the token in an error message or prints it.

///|
fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(index) =>
      if index <= 0 {
        "/"
      } else {
        path.substring(start=0, end=index)
      }
    None => ""
  }
}

///|
/// Persist the credential. The token must be exactly 64 lowercase hex
/// characters (a 32-byte credential); anything else is refused so a caller
/// cannot accidentally write a malformed or over-long secret.
pub async fn save_token_file(path : String, token : String) -> Result[Unit, String] {
  if !is_hex_of_length(token, CREDENTIAL_HEX_LEN) {
    return Err("refusing to persist a malformed credential")
  }
  let dir = parent_dir(path)
  if dir != "" {
    @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
      error => return Err("cannot create token directory: " + safe_error(error))
    }
    @fs.chmod(dir, 0o700) catch {
      error => return Err("cannot secure token directory: " + safe_error(error))
    }
    match stat_path(dir) {
      Some(info) =>
        match info.kind {
          Directory =>
            if !is_private_mode(info.mode) {
              return Err("token directory must be 0700")
            }
          _ => return Err("token directory is not a directory")
        }
      None => return Err("token directory is missing")
    }
  }
  let temp = path + ".tmp"
  @fs.write_file(temp, token, permission=0o600, sync=@fs.SyncMode::Full) catch {
    error => return Err("cannot write token file: " + safe_error(error))
  }
  @fs.chmod(temp, 0o600) catch { _ => () }
  @fs.rename(temp, path, replace=true) catch {
    error => return Err("cannot replace token file: " + safe_error(error))
  }
  Ok(())
}

///|
/// Load the credential. Fails closed when the file is missing, not exactly
/// 0600, not a regular file or not a valid credential shape. Error messages
/// name the path only.
pub async fn load_token_file(path : String) -> Result[String, String] {
  match stat_path(path) {
    None => return Err("token file is missing")
    Some(info) =>
      match info.kind {
        Regular =>
          if (info.mode & 0o777) != 0o600 {
            return Err(
              "token file must be 0600 (found mode " +
              mode_text(info.mode) + ")",
            )
          }
        _ => return Err("token file is not a regular file")
      }
  }
  let data = @fs.read_file(path) catch {
    error => return Err("cannot read token file: " + safe_error(error))
  }
  let text = data.text() catch {
    error => return Err("cannot decode token file: " + safe_error(error))
  }
  let token = text.trim().to_owned()
  if !is_hex_of_length(token, CREDENTIAL_HEX_LEN) {
    return Err("token file does not contain a valid credential")
  }
  Ok(token)
}
