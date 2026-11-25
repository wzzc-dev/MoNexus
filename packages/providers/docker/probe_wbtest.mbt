///|
/// Whitebox process-probe tests. The docker argv is injected into the private
/// probe entry point and every child process is a deterministic `/bin/sh`
/// invocation, so these tests behave identically on a laptop and on the
/// Ubuntu CI runner: no host docker installation, PATH lookup or executable
/// temp file is involved.

///|
fn probe_info_json(version : String, rootless : Bool) -> String {
  let security = if rootless { "[\"name=apparmor\",\"name=rootless\"]" } else { "[\"name=apparmor\"]" }
  "{\"ServerVersion\":\"" + version + "\",\"CgroupVersion\":\"2\"," +
  "\"CgroupDriver\":\"systemd\",\"SecurityOptions\":" + security +
  ",\"Architecture\":\"x86_64\",\"OSType\":\"linux\"," +
  "\"UnrelatedNewField\":{\"nested\":true}}"
}

///|
fn print_json_script(info : String) -> String {
  // The JSON fixture contains double quotes only; single quoting keeps it one
  // literal argument to the shell builtin, with no interpolation.
  "printf '%s' '" + info + "'"
}

///|
async fn probe_with_shell(script : String, timeout_ms : Int) -> DockerProbe {
  probe_docker_argv("/bin/sh", ["-c", script], timeout_ms)
}

///|
async test "probe reports a reachable daemon and its capabilities" {
  let info = probe_info_json("27.1.1", false)
  let probe = probe_with_shell(print_json_script(info), 2_000)
  inspect(probe.available, content="true")
  inspect(probe.schedulable, content="true")
  inspect(probe.is_usable(), content="true")
  match probe.reason() {
    None => ()
    Some(value) => fail("usable probe reported a failure: " + value)
  }
  match probe.capabilities {
    Some(value) =>
      inspect(value.server_version.text(), content="27.1.1")
    None => fail("probe lost its capabilities")
  }
}

///|
async test "probe treats a non-zero exit as unavailable" {
  let probe = probe_with_shell("exit 3", 2_000)
  inspect(probe.available, content="false")
  inspect(probe.schedulable, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_unavailable")
    None => fail("non-zero exit must have a reason")
  }
}

///|
async test "probe times out without pretending to be available" {
  let probe = probe_with_shell("exec /bin/sleep 30", 150)
  inspect(probe.available, content="false")
  inspect(probe.schedulable, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_probe_timeout")
    None => fail("timeout must have a reason")
  }
}

///|
async test "an old daemon is reachable but not schedulable" {
  let info = probe_info_json("19.03.15", false)
  let probe = probe_with_shell(print_json_script(info), 2_000)
  inspect(probe.available, content="true")
  inspect(probe.schedulable, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_version_unsupported")
    None => fail("old daemon must have a reason")
  }
}

///|
async test "an available daemon with malformed info is not schedulable" {
  let probe = probe_with_shell("printf 'not-json'", 2_000)
  inspect(probe.available, content="true")
  inspect(probe.schedulable, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_info_invalid")
    None => fail("malformed info must have a reason")
  }
}
