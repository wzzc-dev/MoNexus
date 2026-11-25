///|
/// Capability-probe tests. The daemon is never touched: parsing is tested
/// directly, and probe behaviour is exercised with fake `docker` scripts in a
/// temp directory so missing/timeout/non-zero paths are deterministic.

///|
async fn test_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
async fn write_script(dir : String, name : String, body : String) -> String raise {
  let path = dir + "/" + name
  @fs.write_file(path, body, permission=0o755) catch {
    _ => fail("cannot write fake docker script")
  }
  @fs.chmod(path, 0o755) catch { _ => fail("cannot chmod fake docker script") }
  path
}

///|
fn docker_info_json(version : String, rootless : Bool) -> String {
  let security = if rootless { "[\"name=apparmor\",\"name=rootless\"]" } else { "[\"name=apparmor\"]" }
  "{\"ServerVersion\":\"" + version + "\",\"CgroupVersion\":\"2\"," +
  "\"CgroupDriver\":\"systemd\",\"SecurityOptions\":" + security +
  ",\"Architecture\":\"x86_64\",\"OSType\":\"linux\"," +
  "\"UnrelatedNewField\":{\"nested\":true}}"
}

///|
fn version_text(text : String) -> String {
  match @docker.DockerServerVersion::parse(text) {
    Some(value) => value.text()
    None => "none"
  }
}

///|
test "server versions parse strictly and ignore custom suffixes" {
  inspect(version_text("20.10.0"), content="20.10.0")
  inspect(version_text("27.1.1"), content="27.1.1")
  inspect(version_text("24.0.9+azure-1"), content="24.0.9")
  inspect(version_text("20.10.0-rc1"), content="20.10.0")
  for bad in ["", "20.10", "v20.10.0", "20.010.0", "20.10.0.1", "20..0", "20.10.0 beta"] {
    inspect(version_text(bad), content="none")
  }
}

///|
test "capabilities parse from docker info and report rootless/cgroup facts" {
  let info = docker_info_json("27.1.1", true)
  let capabilities = match @docker.parse_docker_info(info) {
    Ok(value) => value
    Err(error) => fail("valid docker info rejected: " + error.to_string())
  }
  inspect(capabilities.server_version.text(), content="27.1.1")
  inspect(capabilities.rootless, content="true")
  inspect(capabilities.cgroup_v2, content="true")
  inspect(capabilities.cgroup_driver, content="systemd")
  inspect(capabilities.architecture, content="x86_64")
  inspect(capabilities.os_type, content="linux")
  inspect(
    capabilities.server_version.at_least(20, 10, 0),
    content="true",
  )
  inspect(
    capabilities.server_version.at_least(28, 0, 0),
    content="false",
  )
}

///|
test "docker info rejects missing and malformed facts" {
  let cases : Array[(String, String)] = [
    ("{}", "docker_info_invalid"),
    ("[]", "docker_info_invalid"),
    ("{\"ServerVersion\":\"\"}", "docker_info_invalid"),
    ("{\"ServerVersion\":\"20.10\"}", "docker_info_invalid"),
    ("{\"ServerVersion\":\"20.10.0\",\"CgroupVersion\":\"3\"}", "docker_info_invalid"),
    ("{\"ServerVersion\":\"20.10.0\",\"SecurityOptions\":\"rootless\"}", "docker_info_invalid"),
    ("{\"ServerVersion\":\"20.10.0\",\"SecurityOptions\":[1]}", "docker_info_invalid"),
    ("{\"ServerVersion\":\"20.10.0\",\"CgroupDriver\":1}", "docker_info_invalid"),
    ("not json", "docker_info_invalid"),
  ]
  for entry in cases {
    match @docker.parse_docker_info(entry.0) {
      Ok(_) => fail("docker info should be rejected: " + entry.0)
      Err(error) =>
        if error.reason() != entry.1 {
          fail("expected " + entry.1 + " but got " + error.to_string())
        }
    }
  }
}

///|
test "required flags are derived from the server version" {
  let modern = match @docker.DockerServerVersion::parse("20.10.0") {
    Some(value) => value
    None => fail("version fixture rejected")
  }
  inspect(@docker.missing_required_flags(modern).length(), content="0")
  let ancient = match @docker.DockerServerVersion::parse("1.8.0") {
    Some(value) => value
    None => fail("version fixture rejected")
  }
  let missing = @docker.missing_required_flags(ancient)
  inspect(missing.length(), content="5")
  let labels = StringBuilder()
  for flag in missing {
    if labels.to_string() != "" {
      labels.write_string(",")
    }
    labels.write_string(flag.label())
  }
  inspect(
    labels.to_string(),
    content="env_file,init,pids_limit,cpus,mount_bind",
  )
}

///|
async test "probe reports a reachable daemon and its capabilities" {
  let dir = @fs.tmpdir(prefix="docker-probe-ok") catch {
    _ => fail("cannot create temp directory")
  }
  defer @async.protect_from_cancel(async fn() { test_cleanup(dir) })
  let info = docker_info_json("27.1.1", false)
  let tool = write_script(
    dir,
    "docker-ok",
    "#!/bin/sh\ncat <<'EOF'\n" + info + "\nEOF\n",
  )
  let probe = @docker.probe_docker(tool=tool, timeout_ms=2_000)
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
  let dir = @fs.tmpdir(prefix="docker-probe-fail") catch {
    _ => fail("cannot create temp directory")
  }
  defer @async.protect_from_cancel(async fn() { test_cleanup(dir) })
  let tool = write_script(dir, "docker-fail", "#!/bin/sh\nexit 3\n")
  let probe = @docker.probe_docker(tool=tool, timeout_ms=2_000)
  inspect(probe.available, content="false")
  inspect(probe.schedulable, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_unavailable")
    None => fail("non-zero exit must have a reason")
  }
}

///|
async test "probe times out without pretending to be available" {
  let dir = @fs.tmpdir(prefix="docker-probe-timeout") catch {
    _ => fail("cannot create temp directory")
  }
  defer @async.protect_from_cancel(async fn() { test_cleanup(dir) })
  let tool = write_script(dir, "docker-slow", "#!/bin/sh\nsleep 2\n")
  let probe = @docker.probe_docker(tool=tool, timeout_ms=150)
  inspect(probe.available, content="false")
  inspect(probe.schedulable, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_probe_timeout")
    None => fail("timeout must have a reason")
  }
}

///|
async test "probe fails closed when the executable is missing" {
  let dir = @fs.tmpdir(prefix="docker-probe-missing") catch {
    _ => fail("cannot create temp directory")
  }
  defer @async.protect_from_cancel(async fn() { test_cleanup(dir) })
  let probe = @docker.probe_docker(tool=dir + "/no-such-docker", timeout_ms=500)
  inspect(probe.available, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_missing")
    None => fail("missing tool must have a reason")
  }
}

///|
async test "an old daemon is reachable but not schedulable" {
  let dir = @fs.tmpdir(prefix="docker-probe-old") catch {
    _ => fail("cannot create temp directory")
  }
  defer @async.protect_from_cancel(async fn() { test_cleanup(dir) })
  let info = docker_info_json("19.03.15", false)
  let tool = write_script(
    dir,
    "docker-old",
    "#!/bin/sh\ncat <<'EOF'\n" + info + "\nEOF\n",
  )
  let probe = @docker.probe_docker(tool=tool, timeout_ms=2_000)
  inspect(probe.available, content="true")
  inspect(probe.schedulable, content="false")
  match probe.reason() {
    Some(value) => inspect(value, content="docker_version_unsupported")
    None => fail("old daemon must have a reason")
  }
}
