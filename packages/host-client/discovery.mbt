///|
/// Default state directory: `$MONEXUS_STATE_DIR`, else `$HOME/.monexus`,
/// else `.monexus` in the current directory. M1 has no config file.
pub fn default_state_dir() -> String {
  match @env.get_env_var("MONEXUS_STATE_DIR") {
    Some(value) if value != "" => return value
    _ => ()
  }
  match @env.get_env_var("HOME") {
    Some(home) if home != "" => home + "/.monexus"
    _ => ".monexus"
  }
}

///|
/// Read and validate `host.json` from the state directory. A missing or
/// malformed file is reported as a plain message so the desktop can show an
/// offline reason instead of failing to start.
pub async fn read_host_info(
  state_dir : String,
) -> Result[@contracts.HostInfo, String] {
  let path = @contracts.host_info_path(state_dir)
  let text = @fs.read_file(path).text() catch {
    error => return Err("cannot read " + path + ": " + error.to_string())
  }
  let json = @json.parse(text) catch {
    error => return Err("invalid host.json: " + error.to_string())
  }
  match @contracts.HostInfo::from_json(json) {
    Some(info) => Ok(info)
    None =>
      return Err(
        "invalid host.json: missing schema_version/host_id/token/ws_url",
      )
  }
}
